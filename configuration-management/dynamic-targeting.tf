# Dynamic Targeting via Lambda + Resource Groups
# Lambda queries SSM inventory and tags instances, Resource Groups auto-populate based on tags
# Maintenance windows target Resource Groups (scales to thousands of instances)

locals {
  # Extract maintenance windows that use dynamic targeting
  dynamic_targeting_windows = {
    for window_name, window in local.maintenance_windows :
    window_name => window
    if window.dynamic_targeting != null
  }

  # Create unique targeting configurations
  # Key: composite of baseline + platform details (ensures Rocky 8 and Rocky 9 get separate Lambdas)
  # Example: "rocky-prod-rockylinux-9" vs "rocky-prod-rockylinux-8"
  dynamic_targeting_configs_raw = {
    for window_name, window in local.dynamic_targeting_windows :
    "${local.maintenance_windows[window_name].baseline}-${lower(replace(window.dynamic_targeting.platform_name, " ", ""))}-${window.dynamic_targeting.platform_version}" => {
      baseline            = local.maintenance_windows[window_name].baseline
      platform_name       = window.dynamic_targeting.platform_name
      platform_version    = window.dynamic_targeting.platform_version
      update_schedule     = window.dynamic_targeting.update_schedule
      max_instances       = window.dynamic_targeting.max_instances
      application_filters = window.dynamic_targeting.application_filters
    }...
  }

  # Deduplicate: if multiple windows have identical targeting, keep one config per unique key
  dynamic_targeting_configs_deduped = {
    for key, configs in local.dynamic_targeting_configs_raw :
    key => configs[0]
  }

  # Map long keys to short hash-based keys (for AWS name length limits)
  # Resource names have length limits (e.g., CloudWatch Event Rules = 64 chars)
  # Hash ensures collision resistance while keeping names short
  dynamic_targeting_key_map = {
    for long_key, config in local.dynamic_targeting_configs_deduped :
    long_key => substr(sha256(long_key), 0, 12)
  }

  # Final configs map with hashed keys (used by all resources)
  dynamic_targeting_configs = {
    for long_key, config in local.dynamic_targeting_configs_deduped :
    local.dynamic_targeting_key_map[long_key] => merge(config, {
      original_key = long_key # Keep for reference/debugging
    })
  }

  # Check if any windows use dynamic targeting
  dynamic_targeting_enabled = length(local.dynamic_targeting_configs) > 0
}

# Lambda function code archive
data "archive_file" "dynamic_targeting_lambda" {
  count = local.dynamic_targeting_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/tag_instances_from_inventory.py"
  output_path = "${path.module}/.terraform/lambda/tag_instances_from_inventory.zip"
}

# Lambda function (one per unique targeting config)
resource "aws_lambda_function" "dynamic_targeting" {
  for_each = local.dynamic_targeting_configs

  function_name = "ssm-dynamic-targeting-${each.key}-${var.namespace}"
  description   = "Tags instances for ${each.value.baseline} baseline - ${replace(each.value.platform_name, "*", "")} ${each.value.platform_version} - based on SSM inventory"
  role          = var.access_iam_role_arns["configuration-management-dynamic-targeting-lambda"]
  handler       = "tag_instances_from_inventory.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300 # Increased from 60s to 300s (5 min) for application inventory queries

  filename         = data.archive_file.dynamic_targeting_lambda[0].output_path
  source_code_hash = data.archive_file.dynamic_targeting_lambda[0].output_base64sha256

  environment {
    variables = {
      PLATFORM_NAME    = each.value.platform_name
      PLATFORM_VERSION = each.value.platform_version
      TAG_KEY          = "Patch Group"
      TAG_VALUE        = "${each.value.baseline}-${var.namespace}"
      MAX_INSTANCES    = tostring(each.value.max_instances)
      # Application filters (JSON-encoded, optional)
      APPLICATION_FILTERS = (
        each.value.application_filters != null
        ? jsonencode({
          exclude_patterns = coalesce(each.value.application_filters.exclude_patterns, [])
          include_patterns = coalesce(each.value.application_filters.include_patterns, [])
        })
        : ""
      )
    }
  }

  tags = {
    Name      = "ssm-dynamic-targeting-${each.key}-${var.namespace}"
    Namespace = var.namespace
    Baseline  = each.value.baseline
  }
}

# EventBridge rule to trigger Lambda on schedule
resource "aws_cloudwatch_event_rule" "dynamic_targeting" {
  for_each = local.dynamic_targeting_configs

  name                = "ssm-dynamic-targeting-${each.key}-${var.namespace}"
  description         = "Trigger Lambda to tag instances for ${each.value.baseline} baseline - ${replace(each.value.platform_name, "*", "")} ${each.value.platform_version}"
  schedule_expression = each.value.update_schedule

  tags = {
    Name      = "ssm-dynamic-targeting-${each.key}-${var.namespace}"
    Namespace = var.namespace
    Baseline  = each.value.baseline
  }
}

# EventBridge target (Lambda function)
resource "aws_cloudwatch_event_target" "dynamic_targeting" {
  for_each = local.dynamic_targeting_configs

  rule      = aws_cloudwatch_event_rule.dynamic_targeting[each.key].name
  target_id = "lambda"
  arn       = aws_lambda_function.dynamic_targeting[each.key].arn
}

# Lambda permission for EventBridge to invoke
resource "aws_lambda_permission" "dynamic_targeting" {
  for_each = local.dynamic_targeting_configs

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dynamic_targeting[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dynamic_targeting[each.key].arn
}

# Resource Group for dynamic targeting (tag-based query)
# This auto-populates with instances tagged by the Lambda function
resource "aws_resourcegroups_group" "dynamic_targeting" {
  for_each = local.dynamic_targeting_configs

  name        = "ssm-patch-${each.key}-${var.namespace}"
  description = "Instances for ${each.value.baseline} baseline - ${replace(each.value.platform_name, "*", "")} ${each.value.platform_version} - auto-populated by Lambda tagging"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::EC2::Instance"]
      TagFilters = [
        {
          Key    = "Patch Group"
          Values = ["${each.value.baseline}-${var.namespace}"]
        }
      ]
    })
  }

  tags = {
    Name      = "ssm-patch-${each.key}-${var.namespace}"
    Namespace = var.namespace
    Baseline  = each.value.baseline
  }
}
