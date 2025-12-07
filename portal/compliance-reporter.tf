# Patch Compliance Reporter
# Webhook ingests runtime compliance data from Lambda (SSM patch states)
# Lambda request definition is passed to configuration-management module via dependency inversion

# Port webhook for ingesting compliance data from Lambda
# Uses JQ mapping to upsert entity properties without overwriting Terraform-managed fields
resource "port_webhook" "patch_compliance" {
  count = length(var.patch_management_by_class) > 0 ? 1 : 0

  identifier = "patchCompliance-${var.namespace}"
  title      = "Patch Compliance (${var.namespace})"
  icon       = "RestApi"
  enabled    = true

  mappings = [
    {
      blueprint = local.bp_compute_instance
      operation = {
        type = "create"
      }
      filter = ".body.entity_identifier != null"
      entity = {
        identifier = ".body.entity_identifier"
        title      = ".body.entity_identifier | split(\"-${var.namespace}\") | join(\"\")"
        properties = {
          patchComplianceStatus = ".body.compliance_status"
          patchLastScanTime     = ".body.last_scan_time"
          patchInstalledCount   = ".body.installed_count | tonumber"
          patchMissingCount     = ".body.missing_count | tonumber"
        }
      }
    }
  ]

  depends_on = []
}

# Lambda request definition for configuration-management module (dependency inversion)
# Configuration-management creates the actual Lambda, EventBridge rule, and IAM resources
locals {
  patch_compliance_lambda_request = length(var.patch_management_by_class) > 0 ? [
    {
      name        = "patch-compliance-reporter"
      handler     = "main.handler"
      runtime     = "python3.12"
      timeout     = 120
      schedule    = "rate(15 minutes)"
      source_path = "${path.module}/lambdas/patch-compliance/main.py"
      environment = {
        WEBHOOK_URL  = port_webhook.patch_compliance[0].url
        PATCH_GROUPS = jsonencode([for _, config in var.patch_management_by_class : config.patch_group])
        NAMESPACE    = var.namespace
      }
      iam_statements = [
        {
          actions   = ["ssm:DescribeInstancePatchStatesForPatchGroup"]
          resources = ["*"]
        },
        {
          actions   = ["ec2:DescribeInstances"]
          resources = ["*"]
        }
      ]
    }
  ] : []
}
