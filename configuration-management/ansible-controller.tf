# Ansible Controller via CodeBuild
# Runs Ansible playbooks from an ephemeral CodeBuild instance, connecting to targets
# via the amazon.aws.aws_ssm connection plugin (SSM Session Manager as transport).
# No Ansible installation on targets, cross-platform capable, richer compliance reporting.
#
# Architecture:
#   EventBridge (configurable schedule) -> CodeBuild -> reads manifest.json from S3
#   -> for each playbook entry: generates dynamic inventory, runs ansible-playbook
#   -> callback plugin pushes compliance to SSM via PutComplianceItems

locals {
  ansible_controller_enabled = length(local.ansible_application_requests) > 0

  # Controller script files to upload to S3
  ansible_controller_files = local.ansible_controller_enabled ? {
    "buildspec.yml"                      = "${path.root}/applications/ansible/controller/buildspec.yml"
    "orchestrator.py"                    = "${path.root}/applications/ansible/controller/orchestrator.py"
    "callback_plugins/ssm_compliance.py" = "${path.root}/applications/ansible/controller/callback_plugins/ssm_compliance.py"
    "ansible.cfg"                        = "${path.root}/applications/ansible/controller/ansible.cfg"
    "requirements.yml"                   = "${path.root}/applications/ansible/controller/requirements.yml"
  } : {}

  # Build manifest entries from ansible application requests
  ansible_controller_manifest = {
    region     = var.aws_region
    ssm_bucket = var.application_scripts_bucket
    namespace  = var.namespace
    entries = [
      for req in local.ansible_application_requests : {
        name          = req.playbook
        playbook_file = "${req.playbook}/${coalesce(req.playbook_file, "playbook.yml")}"
        targeting = coalesce(req.targeting_mode, "compute") == "cluster" ? {
          # Cluster mode: multi-host inventory with per-node host_vars
          # Ansible runs all nodes in parallel via forks; no sequential per-instance entries
          mode  = "cluster"
          hosts = req.hosts
          # Unused in cluster mode
          class       = null
          tenant      = null
          tag_key     = null
          tags        = null
          instance_id = null
          } : {
          mode = coalesce(req.targeting_mode, "compute")
          # Compute mode: tag-based targeting (Class + Tenant tags)
          class   = coalesce(req.targeting_mode, "compute") == "compute" ? req.target_tag_value : null
          tenant  = coalesce(req.targeting_mode, "compute") == "compute" ? req.tenant : null
          tag_key = coalesce(req.targeting_mode, "compute") == "compute" ? req.target_tag_key : null
          # Tags mode: custom tag filters
          tags = coalesce(req.targeting_mode, "compute") == "tags" ? {
            for target in coalesce(req.targets, []) :
            replace(target.key, "tag:", "") => target.values
          } : null
          # Instance mode: direct targeting by ID
          instance_id = coalesce(req.targeting_mode, "compute") == "instance" ? req.instance_id : null
          # Unused in non-cluster modes
          hosts = null
        }
        params = merge(
          coalesce(req.params, {}),
          {
            AWS_REGION               = var.aws_region
            DEPLOYMENT_NAMESPACE     = var.namespace
            ANSIBLE_PLAYBOOKS_BUCKET = var.application_scripts_bucket
          },
          req.tenant != null ? { TENANT = req.tenant } : {}
        )
        compliance_severity = "HIGH"
        timeout_seconds     = 1200
      }
    ]
  }
}

# ========================================
# Manifest Upload to S3
# ========================================
resource "aws_s3_object" "ansible_controller_manifest" {
  count = local.ansible_controller_enabled ? 1 : 0

  bucket  = var.application_scripts_bucket
  key     = "ansible-controller/manifest.json"
  content = jsonencode(local.ansible_controller_manifest)

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# Upload controller scripts to S3
resource "aws_s3_object" "ansible_controller_files" {
  for_each = local.ansible_controller_files

  bucket = var.application_scripts_bucket
  key    = "ansible-controller/${each.key}"
  source = each.value
  etag   = filemd5(each.value)

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# ========================================
# CodeBuild IAM - roles and inline policies created by access via access_requests.
# ansible-controller policy is in access_requests (config/variable-derived).
# ansible-controller-scheduler policy stays local (references module-internal codebuild project ARN).
# ========================================

# ========================================
# CodeBuild Project
# ========================================
resource "aws_codebuild_project" "ansible_controller" {
  count = local.ansible_controller_enabled ? 1 : 0

  name                   = "ansible-controller-${var.namespace}"
  description            = "Ansible controller for ${var.namespace}  -  runs playbooks against targets via SSM"
  build_timeout          = 240
  concurrent_build_limit = 1
  service_role           = var.access_iam_role_arns["configuration-management-ansible-controller"]

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable {
      name  = "MANIFEST_BUCKET"
      value = var.application_scripts_bucket
    }

    environment_variable {
      name  = "MANIFEST_KEY"
      value = "ansible-controller/manifest.json"
    }

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        install:
          commands:
            - pip install ansible boto3 botocore pyyaml
            - curl -sL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/ssm.deb && dpkg -i /tmp/ssm.deb
        build:
          commands:
            - aws s3 cp "s3://$${MANIFEST_BUCKET}/ansible-controller/manifest.json" manifest.json
            - aws s3 sync "s3://$${MANIFEST_BUCKET}/ansible-playbooks/" ansible-playbooks/
            - aws s3 cp "s3://$${MANIFEST_BUCKET}/ansible-controller/" controller/ --recursive --exclude "buildspec.yml" --exclude "manifest.json"
            - ansible-galaxy collection install -r controller/requirements.yml
            - ANSIBLE_CONFIG=controller/ansible.cfg python3 controller/orchestrator.py --manifest manifest.json --playbooks-dir ansible-playbooks
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/ansible-controller-${var.namespace}"
    }
  }

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# ========================================
# EventBridge Scheduler
# ========================================
resource "aws_scheduler_schedule" "ansible_controller" {
  count = local.ansible_controller_enabled ? 1 : 0

  name        = "ansible-controller-${var.namespace}"
  description = "Trigger Ansible controller CodeBuild project on schedule"
  group_name  = "default"

  schedule_expression          = var.config.ansible_schedule
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 5
  }

  target {
    arn      = aws_codebuild_project.ansible_controller[0].arn
    role_arn = var.access_iam_role_arns["configuration-management-ansible-controller-scheduler"]

    # Retry failed invocations
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 1
    }
  }
}

# Scheduler role created by access; policy stays local (references module-internal codebuild project ARN)
resource "aws_iam_role_policy" "ansible_controller_scheduler" {
  count = local.ansible_controller_enabled ? 1 : 0

  name = "ansible-controller-scheduler-${var.namespace}"
  role = var.access_iam_role_names["configuration-management-ansible-controller-scheduler"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild"
        ]
        Resource = aws_codebuild_project.ansible_controller[0].arn
      }
    ]
  })
}
