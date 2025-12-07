# Generic Lambda Interface (Dependency Inversion)
# Creates Lambda functions, EventBridge rules, and IAM resources from external module requests
# Follows the same pattern as dynamic-targeting.tf but generalized for any scheduled Lambda

locals {
  # Convert list to map keyed by name for for_each usage
  lambda_requests = {
    for req in var.lambda_requests : req.name => req
  }
}

# Package Lambda source code into zip archives
data "archive_file" "requested_lambda" {
  for_each = local.lambda_requests

  type        = "zip"
  source_file = each.value.source_path
  output_path = "${path.module}/.terraform/lambda/${each.key}.zip"
}

# Shared IAM role for all requested Lambda functions
resource "aws_iam_role" "requested_lambda" {
  count = length(local.lambda_requests) > 0 ? 1 : 0

  name        = "requested-lambda-${var.namespace}"
  description = "Lambda role for externally-requested scheduled functions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name      = "requested-lambda-${var.namespace}"
    Namespace = var.namespace
  }
}

# Per-request IAM policy (CloudWatch Logs + custom statements)
resource "aws_iam_role_policy" "requested_lambda" {
  for_each = local.lambda_requests

  name = "requested-lambda-${each.key}"
  role = aws_iam_role.requested_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:*:*:*"
        }
      ],
      [
        for stmt in each.value.iam_statements : {
          Effect   = "Allow"
          Action   = stmt.actions
          Resource = stmt.resources
        }
      ]
    )
  })
}

# Lambda function per request
resource "aws_lambda_function" "requested_lambda" {
  for_each = local.lambda_requests

  function_name = "${each.key}-${var.namespace}"
  description   = "Scheduled Lambda: ${each.key} (${var.namespace})"
  role          = aws_iam_role.requested_lambda[0].arn
  handler       = each.value.handler
  runtime       = each.value.runtime
  timeout       = each.value.timeout

  filename         = data.archive_file.requested_lambda[each.key].output_path
  source_code_hash = data.archive_file.requested_lambda[each.key].output_base64sha256

  environment {
    variables = each.value.environment
  }

  tags = {
    Name      = "${each.key}-${var.namespace}"
    Namespace = var.namespace
  }
}

# EventBridge rule to trigger Lambda on schedule
resource "aws_cloudwatch_event_rule" "requested_lambda" {
  for_each = local.lambda_requests

  name                = "${each.key}-${var.namespace}"
  description         = "Trigger ${each.key} Lambda on schedule"
  schedule_expression = each.value.schedule

  tags = {
    Name      = "${each.key}-${var.namespace}"
    Namespace = var.namespace
  }
}

# EventBridge target (Lambda function)
resource "aws_cloudwatch_event_target" "requested_lambda" {
  for_each = local.lambda_requests

  rule      = aws_cloudwatch_event_rule.requested_lambda[each.key].name
  target_id = "lambda"
  arn       = aws_lambda_function.requested_lambda[each.key].arn
}

# Lambda permission for EventBridge to invoke
resource "aws_lambda_permission" "requested_lambda" {
  for_each = local.lambda_requests

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.requested_lambda[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.requested_lambda[each.key].arn
}
