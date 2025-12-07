# Event Bus Integration
# Captures CodeBuild lifecycle events and posts to Port event bus webhook

# EventBridge rule to capture CodeBuild state changes
resource "aws_cloudwatch_event_rule" "codebuild_events" {
  count = local.ansible_controller_enabled && length(var.event_bus_webhooks) > 0 ? 1 : 0

  name        = "codebuild-events-${var.namespace}"
  description = "Capture CodeBuild lifecycle events for event bus"

  event_pattern = jsonencode({
    source      = ["aws.codebuild"]
    detail-type = ["CodeBuild Build State Change"]
    detail = {
      project-name = [aws_codebuild_project.ansible_controller[0].name]
    }
  })

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# Lambda to transform EventBridge event to Port webhook format
resource "aws_lambda_function" "codebuild_event_reporter" {
  count = local.ansible_controller_enabled && length(var.event_bus_webhooks) > 0 ? 1 : 0

  function_name = "codebuild-event-reporter-${var.namespace}"
  description   = "Transform CodeBuild events for Port event bus"
  role          = var.access_iam_role_arns["configuration-management-codebuild-event-reporter"]
  handler       = "main.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.codebuild_event_reporter[0].output_path
  source_code_hash = data.archive_file.codebuild_event_reporter[0].output_base64sha256

  environment {
    variables = {
      WEBHOOK_URL    = var.event_bus_webhooks["codebuild-lifecycle"]
      NAMESPACE      = var.namespace
      AWS_REGION_VAR = var.aws_region
      SSO_START_URL  = var.aws_sso_start_url
      ACCOUNT_ID     = var.aws_account_id
    }
  }

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# Package Lambda function
data "archive_file" "codebuild_event_reporter" {
  count = local.ansible_controller_enabled && length(var.event_bus_webhooks) > 0 ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambdas/codebuild-event-reporter/main.py"
  output_path = "${path.module}/.terraform/lambda/codebuild-event-reporter.zip"
}

# EventBridge target
resource "aws_cloudwatch_event_target" "codebuild_event_reporter" {
  count = local.ansible_controller_enabled && length(var.event_bus_webhooks) > 0 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.codebuild_events[0].name
  target_id = "lambda"
  arn       = aws_lambda_function.codebuild_event_reporter[0].arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "codebuild_event_reporter" {
  count = local.ansible_controller_enabled && length(var.event_bus_webhooks) > 0 ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.codebuild_event_reporter[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.codebuild_events[0].arn
}
