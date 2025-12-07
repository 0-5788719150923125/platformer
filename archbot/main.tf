# archbot Module
# Event-driven AI automation pipeline for Atlassian ticket processing.
# Ingests webhook events via API Gateway -> SQS -> Lambda, rebuilds full ticket context
# from the Atlassian REST API, delegates to Devin AI, and posts responses as comments.
#
# Secret ARNs are passed in from the secrets module (dependency inversion).
# The Atlassian PAT requires: Browse Projects, View Issue, Add Comments.

# ── SQS Queues ────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  name                      = "archbot-dlq-${var.namespace}"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name      = "archbot-dlq-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "aws_sqs_queue" "main" {
  name                       = "archbot-${var.namespace}"
  visibility_timeout_seconds = var.config.queue_visibility_timeout
  message_retention_seconds  = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name      = "archbot-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAPIGateway"
        Effect    = "Allow"
        Principal = { AWS = var.access_iam_role_arns["archbot-api-gateway-sqs"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.main.arn
      }
    ]
  })
}

# ── API Gateway (HTTP API) ────────────────────────────────────────────────────
# Webhook endpoint for Atlassian Automation. Forwards request body to SQS natively
# (no Lambda at the ingestion layer - decouples intake from processing).

resource "aws_apigatewayv2_api" "archbot" {
  name          = "archbot-${var.namespace}"
  protocol_type = "HTTP"
  description   = "Atlassian Automation webhook receiver for archbot (${var.namespace})"

  tags = {
    Name      = "archbot-${var.namespace}"
    Namespace = var.namespace
  }
}

# Tracks the credentials ARN (a variable) so it can be used in replace_triggered_by.
# The AWS provider drops request_parameters on UpdateIntegration for action-based integrations,
# so any change that would trigger an update must instead trigger a full replacement.
resource "terraform_data" "sqs_integration_key" {
  input = var.access_iam_role_arns["archbot-api-gateway-sqs"]
}

resource "aws_apigatewayv2_integration" "sqs" {
  api_id              = aws_apigatewayv2_api.archbot.id
  integration_type    = "AWS_PROXY"
  integration_subtype = "SQS-SendMessage"
  credentials_arn     = var.access_iam_role_arns["archbot-api-gateway-sqs"]

  request_parameters = {
    "QueueUrl"    = aws_sqs_queue.main.url
    "MessageBody" = "$request.body"
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.sqs_integration_key, aws_sqs_queue.main]
  }
}

resource "aws_apigatewayv2_route" "events" {
  api_id    = aws_apigatewayv2_api.archbot.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.sqs.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.archbot.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name      = "archbot-${var.namespace}"
    Namespace = var.namespace
  }
}

# ── IAM (local policies on access-created roles) ─────────────────────────────
# Roles are created by the access module via access_requests (dependency inversion).
# Only inline policies that reference module-internal resources stay here.

resource "aws_iam_role_policy" "api_gateway_sqs" {
  name = "sqs-send-message"
  role = var.access_iam_role_names["archbot-api-gateway-sqs"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main.arn
      }
    ]
  })
}

resource "aws_ssm_parameter" "system_prompt" {
  name  = "/platformer/${var.namespace}/archbot/system_prompt"
  type  = "String"
  value = var.config.system_prompt

  tags = {
    Namespace = var.namespace
  }
}

resource "aws_iam_role_policy" "lambda" {
  name = "archbot-lambda-${var.namespace}"
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
        Resource = [aws_sqs_queue.main.arn, aws_sqs_queue.dlq.arn]
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = [var.atlassian_secret_arn, var.devin_secret_arn]
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.system_prompt.arn
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

# ── Lambda ────────────────────────────────────────────────────────────────────

locals {
  # Hash of all atlassian-bot source files - embedded in the zip path so Terraform
  # recreates the archive (and detects a new source_code_hash) whenever any file changes.
  atlassian_bot_source_hash = sha256(join("", [
    for f in sort(fileset("${path.module}/lambdas/atlassian-bot", "**")) :
    filesha256("${path.module}/lambdas/atlassian-bot/${f}")
  ]))
}

data "archive_file" "atlassian_bot" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/atlassian-bot"
  output_path = "${path.module}/.terraform/lambda/atlassian-bot-${local.atlassian_bot_source_hash}.zip"
}

resource "aws_lambda_function" "atlassian_bot" {
  function_name = "archbot-atlassian-bot-${var.namespace}"
  description   = "Processes Atlassian ticket events via Devin AI and posts responses as comments"
  role          = var.access_iam_role_arns["archbot-lambda"]
  handler       = "main.handler"
  runtime       = "python3.12"
  timeout       = var.config.lambda_timeout
  memory_size   = var.config.lambda_memory

  filename         = data.archive_file.atlassian_bot.output_path
  source_code_hash = data.archive_file.atlassian_bot.output_base64sha256

  environment {
    variables = merge(
      {
        AI_BACKEND          = var.config.ai_backend
        ATLASSIAN_BASE_URL  = var.config.atlassian_base_url
        ATLASSIAN_EMAIL     = var.config.atlassian_email
        ATLASSIAN_SECRET_ID = var.atlassian_secret_arn
        DEVIN_SECRET_ID     = var.devin_secret_arn
        DEVIN_POLL_INTERVAL = tostring(var.config.devin_poll_interval)
        DEVIN_MAX_WAIT      = tostring(var.config.devin_max_wait)
        BEDROCK_MODEL_ID    = var.config.bedrock_model_id
        BEDROCK_MAX_TOKENS  = tostring(var.config.bedrock_max_tokens)
        BEDROCK_TEMPERATURE = tostring(var.config.bedrock_temperature)
        DEBUG_MODE          = tostring(var.config.debug)
        SYSTEM_PROMPT_PARAM = aws_ssm_parameter.system_prompt.name
        DENY_LIST           = jsonencode(var.config.deny_list)
        RESPONSE_RATE       = tostring(var.config.response_rate)
      },
      var.config.knowledge_base_enabled ? {
        KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.archbot[0].id
        KB_MAX_RESULTS    = tostring(var.config.kb_max_results)
      } : {}
    )
  }

  tags = {
    Name      = "archbot-atlassian-bot-${var.namespace}"
    Namespace = var.namespace
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn        = aws_sqs_queue.main.arn
  function_name           = aws_lambda_function.atlassian_bot.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}
