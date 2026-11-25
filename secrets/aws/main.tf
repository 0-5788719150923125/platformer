# Secrets Module
# Cross-account secret replication - reads secrets from source accounts and creates
# local copies in the deployment account. Instances access local copies via IAM.
#
# Supports two destination types (default: secrets_manager):
#   destination: secrets_manager   -> aws_secretsmanager_secret (default)
#   destination: parameter_store   -> aws_ssm_parameter SecureString
#
# Optional: json_key - when the source secret is JSON, extract this field as a plain string.
#
# Supported source providers:
#   source_provider: "infrastructure"  - reads from example-infrastructure-prod (cross-account)
#   source_provider: "prod"            - reads from example-platform-prod (cross-account)
#   source_provider: "self"            - reads from the deployment account itself
#   source_provider: "dotenv"          - reads from .env file in the repo root
#
# State fragment example:
#   services:
#     secrets:
#       crowdstrike/falcon_clientid:
#         source_secret_id: "crowdstrike/falcon_clientid"
#         source_provider: "infrastructure"
#         description: "CrowdStrike Falcon OAuth2 Client ID"
#         destination: parameter_store
#
# Secrets are namespaced as: platformer/{namespace}/{key}
# Playbooks receive DEPLOYMENT_NAMESPACE via SSM ExtraVariables and use it to resolve paths.
# Use AWS CLI for Secrets Manager access (aws secretsmanager get-secret-value).
# Use AWS CLI for Parameter Store access (aws ssm get-parameter).

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.infrastructure, aws.prod]
    }
  }
}

locals {
  # Split by destination
  secrets_manager_secrets = {
    for k, v in var.config : k => v
    if try(v.destination, "secrets_manager") == "secrets_manager"
  }

  parameter_store_secrets = {
    for k, v in var.config : k => v
    if try(v.destination, "secrets_manager") == "parameter_store"
  }

  # Filter by source provider - one data source per provider alias
  infrastructure_secrets = {
    for k, v in var.config : k => v
    if try(v.source_provider, "") == "infrastructure"
  }

  prod_secrets = {
    for k, v in var.config : k => v
    if try(v.source_provider, "") == "prod"
  }

  self_secrets = {
    for k, v in var.config : k => v
    if try(v.source_provider, "") == "self"
  }

  dotenv_secrets = {
    for k, v in var.config : k => v
    if try(v.source_provider, "") == "dotenv"
  }

  # Parse .env file from repo root: KEY=VALUE lines, skip comments and blanks
  dotenv_raw = fileexists("${path.root}/.env") ? file("${path.root}/.env") : ""

  dotenv_entries = {
    for line in compact(split("\n", local.dotenv_raw)) :
    trimspace(split("=", line)[0]) => join("=", slice(split("=", line), 1, length(split("=", line))))
    if !startswith(trimspace(line), "#") && length(trimspace(line)) > 0
  }

  # Unified lookup: merge source secret strings from all providers into a single map
  # keyed by secret config key, so downstream resources don't need per-provider logic
  source_secret_strings = merge(
    { for k, v in data.aws_secretsmanager_secret_version.infrastructure : k => v.secret_string },
    { for k, v in data.aws_secretsmanager_secret_version.prod : k => v.secret_string },
    { for k, v in data.aws_secretsmanager_secret_version.self : k => v.secret_string },
    { for k, v in local.dotenv_secrets : k => local.dotenv_entries[v.source_secret_id] },
  )
}

# Read from infrastructure account (example-infrastructure-prod)
data "aws_secretsmanager_secret_version" "infrastructure" {
  for_each  = local.infrastructure_secrets
  secret_id = each.value.source_secret_id
  provider  = aws.infrastructure
}

# Read from production account (example-platform-prod)
data "aws_secretsmanager_secret_version" "prod" {
  for_each  = local.prod_secrets
  secret_id = each.value.source_secret_id
  provider  = aws.prod
}

# Read from the deployment account itself
data "aws_secretsmanager_secret_version" "self" {
  for_each  = local.self_secrets
  secret_id = each.value.source_secret_id
}

# Create local copies in the deployment account (Secrets Manager)
resource "aws_secretsmanager_secret" "replicated" {
  for_each                = local.secrets_manager_secrets
  name                    = "platformer/${var.namespace}/${each.key}"
  description             = try(each.value.description, "Replicated from ${try(each.value.source_provider, "unknown")} account")
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "replicated" {
  for_each      = local.secrets_manager_secrets
  secret_id     = aws_secretsmanager_secret.replicated[each.key].id
  secret_string = try(each.value.json_key, null) != null ? jsondecode(local.source_secret_strings[each.key])[each.value.json_key] : local.source_secret_strings[each.key]
}

# Resource policy for account-wide read access
# Opt-in via `access: account` on individual secret entries
# Allows any IAM principal in the account to read the secret value,
# enabling wildcard-targeted SSM associations to work on instances
# with arbitrary IAM roles (absent explicit deny)
locals {
  account_access_secrets = {
    for k, v in local.secrets_manager_secrets : k => v
    if try(v.access, "") == "account"
  }
}

resource "aws_secretsmanager_secret_policy" "account_read" {
  for_each = local.account_access_secrets

  secret_arn = aws_secretsmanager_secret.replicated[each.key].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountRead"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "secretsmanager:GetSecretValue"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}

# Create local copies in the deployment account (SSM Parameter Store)
resource "aws_ssm_parameter" "replicated" {
  for_each = local.parameter_store_secrets

  name        = "/platformer/${var.namespace}/${each.key}"
  description = try(each.value.description, "Replicated from ${try(each.value.source_provider, "unknown")} account")
  type        = "SecureString"
  value       = try(each.value.json_key, null) != null ? jsondecode(local.source_secret_strings[each.key])[each.value.json_key] : local.source_secret_strings[each.key]
}
