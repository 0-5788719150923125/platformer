# Local variables for IAM policy management
locals {
  # Discover IAM policy files (.iam.json) for enabled documents
  iam_policies = {
    for name, doc in local.enabled_documents :
    name => doc
    if doc.has_iam_policy
  }

  # Render IAM policy templates with variable substitution
  rendered_iam_policies = {
    for name, doc in local.iam_policies :
    name => templatefile(doc.iam_policy_file, {
      aws_account_id         = var.aws_account_id
      parameter_store_prefix = var.config.parameter_store_prefix
      region                 = data.aws_region.current.id
    })
  }
}

# Create inline IAM policy for each document that has an IAM policy file
# Inline policies avoid the 10-attachment limit on IAM roles
resource "aws_iam_role_policy" "document_policy" {
  for_each = (var.instances_role_name != "" || var.config.existing_instance_role_name != "") ? local.iam_policies : {}

  name   = "${each.key}-${var.namespace}"
  role   = var.instances_role_name != "" ? var.instances_role_name : var.config.existing_instance_role_name
  policy = local.rendered_iam_policies[each.key]
}

# IAM roles and inline policies are created by the access module via access_requests
# (dependency inversion). Only the document_policy below stays local because it targets
# var.instances_role_name - an external role created outside this module.
#
# IMPORTANT: All values in access_requests must be config/variable-derived (no module-internal
# resource attributes) to avoid Terraform module-closure cycles. Policies that reference
# module resources (e.g., aws_codebuild_project.ansible_controller[0].arn) stay as local
# aws_iam_role_policy resources in their respective .tf files.
locals {
  access_requests = concat(
    # Maintenance window service role (when patch management enabled)
    local.patch_enabled ? [
      {
        module              = "configuration-management"
        type                = "iam-role"
        purpose             = "maintenance-window"
        description         = "SSM Maintenance Windows service role for patch tasks"
        trust_services      = ["ssm.amazonaws.com", "ec2.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies = {
          "ssm-maintenance-window-policy" = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect = "Allow"
                Action = [
                  "ssm:SendCommand",
                  "ssm:CancelCommand",
                  "ssm:ListCommands",
                  "ssm:ListCommandInvocations",
                  "ssm:GetCommandInvocation",
                  "ssm:DescribeInstanceInformation",
                  "ssm:ListTagsForResource",
                  "ssm:GetAutomationExecution",
                  "ssm:StartAutomationExecution"
                ]
                Resource = "*"
              },
              {
                Effect = "Allow"
                Action = [
                  "resource-groups:ListGroups",
                  "resource-groups:ListGroupResources",
                  "tag:GetResources"
                ]
                Resource = "*"
              },
              {
                Effect   = "Allow"
                Action   = ["iam:PassRole"]
                Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.config.existing_instance_role_name}"
                Condition = {
                  StringEquals = {
                    "iam:PassedToService" = "ssm.amazonaws.com"
                  }
                }
              }
            ]
          })
          "hooks-s3-access" = jsonencode({
            Version = "2012-10-17"
            Statement = [{
              Effect = "Allow"
              Action = ["s3:GetObject", "s3:ListBucket"]
              Resource = [
                "arn:aws:s3:::${var.hooks_bucket}",
                "arn:aws:s3:::${var.hooks_bucket}/*"
              ]
            }]
          })
        }
        instance_profile = false
      }
    ] : [],
    # Hybrid instance role (when hybrid activations enabled)
    local.hybrid_activations_enabled ? [
      {
        module              = "configuration-management"
        type                = "iam-role"
        purpose             = "hybrid-instance"
        description         = "SSM hybrid-activated instances service role"
        trust_services      = ["ssm.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
        inline_policies = {
          "parameter-store-access" = jsonencode({
            Version = "2012-10-17"
            Statement = [{
              Effect = "Allow"
              Action = [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath",
                "ssm:PutParameter"
              ]
              Resource = "arn:aws:ssm:*:${var.aws_account_id}:parameter/${var.config.parameter_store_prefix}/*"
            }]
          })
        }
        instance_profile = false
      }
    ] : [],
    # Ansible controller roles - use config-derived var to avoid module-closure cycle
    # (local.ansible_controller_enabled depends on var.application_requests which depends on
    # compute.cluster_application_requests which depends on aws_instance.tenant - cycle!)
    var.ansible_applications_configured ? [
      {
        module              = "configuration-management"
        type                = "iam-role"
        purpose             = "ansible-controller"
        description         = "CodeBuild service role for Ansible controller"
        trust_services      = ["codebuild.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies = {
          "ansible-controller" = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Sid    = "SSMSessionAccess"
                Effect = "Allow"
                Action = [
                  "ssm:StartSession",
                  "ssm:TerminateSession",
                  "ssm:ResumeSession",
                  "ssm:DescribeInstanceInformation",
                  "ssm:GetConnectionStatus"
                ]
                Resource = "*"
              },
              {
                Sid      = "SSMCompliance"
                Effect   = "Allow"
                Action   = ["ssm:PutComplianceItems"]
                Resource = "*"
              },
              {
                Sid      = "EC2Describe"
                Effect   = "Allow"
                Action   = ["ec2:DescribeInstances"]
                Resource = "*"
              },
              {
                Sid    = "S3Access"
                Effect = "Allow"
                Action = [
                  "s3:GetObject",
                  "s3:PutObject",
                  "s3:DeleteObject",
                  "s3:ListBucket",
                  "s3:GetBucketLocation"
                ]
                Resource = [
                  "arn:aws:s3:::${var.application_scripts_bucket}",
                  "arn:aws:s3:::${var.application_scripts_bucket}/*"
                ]
              },
              {
                Sid    = "CloudWatchLogs"
                Effect = "Allow"
                Action = [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents"
                ]
                Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/codebuild/*"
              }
            ]
          })
        }
        instance_profile = false
      },
      {
        module              = "configuration-management"
        type                = "iam-role"
        purpose             = "ansible-controller-scheduler"
        description         = "EventBridge Scheduler role for triggering Ansible controller"
        trust_services      = ["scheduler.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        # StartBuild policy stays local - references aws_codebuild_project.ansible_controller[0].arn
        inline_policies  = {}
        instance_profile = false
      }
    ] : [],
    # Dynamic targeting Lambda role (when dynamic targeting enabled)
    local.dynamic_targeting_enabled ? [
      {
        module              = "configuration-management"
        type                = "iam-role"
        purpose             = "dynamic-targeting-lambda"
        description         = "Lambda role for tagging instances based on SSM inventory"
        trust_services      = ["lambda.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies = {
          "ssm-dynamic-targeting-policy" = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect   = "Allow"
                Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
                Resource = "arn:aws:logs:*:*:*"
              },
              {
                Effect   = "Allow"
                Action   = ["ssm:DescribeInstanceInformation", "ssm:ListInventoryEntries"]
                Resource = "*"
              },
              {
                Effect   = "Allow"
                Action   = ["ec2:CreateTags", "ec2:DeleteTags", "ec2:DescribeTags", "ec2:DescribeInstances"]
                Resource = "*"
              }
            ]
          })
        }
        instance_profile = false
      }
    ] : [],
    # CodeBuild event reporter Lambda role - pre-create whenever ansible is configured
    # Cannot condition on event_bus_webhooks here (portal output creates cycle through event_bus_requests)
    var.ansible_applications_configured ? [
      {
        module              = "configuration-management"
        type                = "iam-role"
        purpose             = "codebuild-event-reporter"
        description         = "Lambda role for CodeBuild event reporter"
        trust_services      = ["lambda.amazonaws.com"]
        trust_roles         = []
        trust_actions       = ["sts:AssumeRole"]
        trust_conditions    = "{}"
        managed_policy_arns = []
        inline_policies = {
          "codebuild-event-reporter" = jsonencode({
            Version = "2012-10-17"
            Statement = [{
              Effect = "Allow"
              Action = [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
              ]
              Resource = "arn:aws:logs:*:*:*"
            }]
          })
        }
        instance_profile = false
      }
    ] : [],
  )
}
