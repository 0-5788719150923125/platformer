# archbot Module
# Multi-target AI automation pipeline. Routes bot configs by target type:
#   - atlassian: API Gateway -> SQS -> Lambda -> Bedrock -> Jira REST API
#   - discord:   Local Docker container -> Bedrock -> Discord API
#
# Secret ARNs are passed in from the secrets module (dependency inversion).

# ── Type-routed locals ───────────────────────────────────────────────────────

locals {
  atlassian_bots = { for n, b in var.config : n => b if b.target == "atlassian" }
  discord_bots   = { for n, b in var.config : n => b if b.target == "discord" }
  kb_bots        = { for n, b in var.config : n => b if b.knowledge_base_enabled }

  # Merge KB doc paths across all KB-enabled bots
  all_kb_document_paths = distinct(flatten([
    for n, b in local.kb_bots : b.kb_document_paths
  ]))
  kb_enabled = length(local.kb_bots) > 0

  has_atlassian_bots = length(local.atlassian_bots) > 0
}

# ── SQS Queues ────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  for_each = local.atlassian_bots

  name                      = "archbot-${each.key}-dlq-${var.namespace}"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name      = "archbot-${each.key}-dlq-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "aws_sqs_queue" "main" {
  for_each = local.atlassian_bots

  name                       = "archbot-${each.key}-${var.namespace}"
  visibility_timeout_seconds = each.value.queue_visibility_timeout
  message_retention_seconds  = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })

  tags = {
    Name      = "archbot-${each.key}-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "aws_sqs_queue_policy" "main" {
  for_each = local.atlassian_bots

  queue_url = aws_sqs_queue.main[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAPIGateway"
        Effect    = "Allow"
        Principal = { AWS = var.access_iam_role_arns["archbot-api-gateway-sqs"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.main[each.key].arn
      }
    ]
  })
}

# ── API Gateway (HTTP API) ────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "archbot" {
  for_each = local.atlassian_bots

  name          = "archbot-${each.key}-${var.namespace}"
  protocol_type = "HTTP"
  description   = "Atlassian Automation webhook receiver for archbot ${each.key} (${var.namespace})"

  tags = {
    Name      = "archbot-${each.key}-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "terraform_data" "sqs_integration_key" {
  for_each = local.atlassian_bots

  input = var.access_iam_role_arns["archbot-api-gateway-sqs"]
}

resource "aws_apigatewayv2_integration" "sqs" {
  for_each = local.atlassian_bots

  api_id              = aws_apigatewayv2_api.archbot[each.key].id
  integration_type    = "AWS_PROXY"
  integration_subtype = "SQS-SendMessage"
  credentials_arn     = var.access_iam_role_arns["archbot-api-gateway-sqs"]

  request_parameters = {
    "QueueUrl"    = aws_sqs_queue.main[each.key].url
    "MessageBody" = "$request.body"
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.sqs_integration_key[each.key], aws_sqs_queue.main[each.key]]
  }
}

resource "aws_apigatewayv2_route" "events" {
  for_each = local.atlassian_bots

  api_id    = aws_apigatewayv2_api.archbot[each.key].id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.sqs[each.key].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  for_each = local.atlassian_bots

  api_id      = aws_apigatewayv2_api.archbot[each.key].id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name      = "archbot-${each.key}-${var.namespace}"
    Namespace = var.namespace
  }
}

# ── IAM (local policies on access-created roles) ─────────────────────────────

resource "aws_iam_role_policy" "api_gateway_sqs" {
  for_each = local.atlassian_bots

  name = "sqs-send-message-${each.key}"
  role = var.access_iam_role_names["archbot-api-gateway-sqs"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main[each.key].arn
      }
    ]
  })
}

# ── SSM System Prompt (all bots) ─────────────────────────────────────────────

resource "aws_ssm_parameter" "system_prompt" {
  for_each = var.config

  name  = "/platformer/${var.namespace}/archbot/${each.key}/system_prompt"
  type  = "String"
  value = each.value.system_prompt

  tags = {
    Namespace = var.namespace
  }
}

# ── Lambda IAM (per atlassian bot) ───────────────────────────────────────────

resource "aws_iam_role_policy" "lambda" {
  for_each = local.atlassian_bots

  name = "archbot-lambda-${each.key}-${var.namespace}"
  role = var.access_iam_role_names["archbot-lambda"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.main[each.key].arn, aws_sqs_queue.dlq[each.key].arn]
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = [var.atlassian_secret_arn, var.devin_secret_arn]
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.system_prompt[each.key].arn
      },
      {
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:*:inference-profile/*",
        ]
      },
      {
        # Read-only IAM introspection for tool-calling (whoami + query_iam_permissions)
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity",
          "iam:GetRole",
          "iam:GetUser",
          "iam:ListAttachedRolePolicies",
          "iam:ListAttachedUserPolicies",
          "iam:ListGroupsForUser",
          "iam:ListRolePolicies",
          "iam:ListUserPolicies",
          "iam:SimulatePrincipalPolicy",
        ]
        Resource = "*"
      }
    ]
  })
}

# ── Lambda Build ──────────────────────────────────────────────────────────────

locals {
  # Hash of shared module - triggers rebuild when shared code changes
  shared_source_hash = sha256(join("", [
    for f in sort(fileset("${path.module}/lambdas/shared", "**")) :
    filesha256("${path.module}/lambdas/shared/${f}")
  ]))
}

resource "null_resource" "build_lambdas" {
  triggers = {
    shared_hash = local.shared_source_hash
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/build-lambdas.sh"
  }
}

locals {
  # Hash of all atlassian-bot source files (including copied shared module)
  atlassian_bot_source_hash = sha256(join("", concat(
    [local.shared_source_hash],
    [for f in sort(fileset("${path.module}/lambdas/atlassian-bot", "**")) :
      filesha256("${path.module}/lambdas/atlassian-bot/${f}")
    ]
  )))
}

data "archive_file" "atlassian_bot" {
  count = local.has_atlassian_bots ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambdas/atlassian-bot"
  output_path = "${path.module}/.terraform/lambda/atlassian-bot-${local.atlassian_bot_source_hash}.zip"

  depends_on = [null_resource.build_lambdas]
}

resource "aws_lambda_function" "atlassian_bot" {
  for_each = local.atlassian_bots

  function_name = "archbot-${each.key}-${var.namespace}"
  description   = "Processes Atlassian ticket events via AI and posts responses as comments (${each.key})"
  role          = var.access_iam_role_arns["archbot-lambda"]
  handler       = "main.handler"
  runtime       = "python3.12"
  timeout       = each.value.lambda_timeout
  memory_size   = each.value.lambda_memory

  filename         = data.archive_file.atlassian_bot[0].output_path
  source_code_hash = data.archive_file.atlassian_bot[0].output_base64sha256

  environment {
    variables = merge(
      {
        AI_BACKEND          = each.value.ai_backend
        ATLASSIAN_BASE_URL  = each.value.atlassian_base_url
        ATLASSIAN_EMAIL     = each.value.atlassian_email
        ATLASSIAN_SECRET_ID = var.atlassian_secret_arn
        DEVIN_SECRET_ID     = var.devin_secret_arn
        DEVIN_POLL_INTERVAL = tostring(each.value.devin_poll_interval)
        DEVIN_MAX_WAIT      = tostring(each.value.devin_max_wait)
        BEDROCK_MODEL_ID    = each.value.bedrock_model_id
        BEDROCK_MAX_TOKENS  = tostring(each.value.bedrock_max_tokens)
        BEDROCK_TEMPERATURE = tostring(each.value.bedrock_temperature)
        DEBUG_MODE          = tostring(each.value.debug)
        SYSTEM_PROMPT_PARAM = aws_ssm_parameter.system_prompt[each.key].name
        DENY_LIST           = jsonencode(each.value.deny_list)
        RESPONSE_RATE       = tostring(each.value.response_rate)
      },
      each.value.knowledge_base_enabled ? {
        KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.archbot[0].id
        KB_MAX_RESULTS    = tostring(each.value.kb_max_results)
      } : {}
    )
  }

  tags = {
    Name      = "archbot-${each.key}-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  for_each = local.atlassian_bots

  event_source_arn        = aws_sqs_queue.main[each.key].arn
  function_name           = aws_lambda_function.atlassian_bot[each.key].arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}
