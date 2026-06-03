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

# ========================================
# On-demand trigger (state-file `redeploy` switch)
# ========================================
# A compute class's `redeploy` switch (true / false / "<nonce>") flows in via
# var.redeploy_triggers. A change to that map replaces this resource and runs
# `start-build` immediately - so a deploy converges now instead of waiting for
# aws_scheduler_schedule.ansible_controller to fire on its interval. `redeploy: true`
# carries a per-apply value, so the build fires on EVERY apply (expect a standing
# plan diff on this resource); a "<nonce>" string fires only when it changes; off
# (false/unset) means this resource doesn't exist and normal applies never build.
#
# Ordering + readiness: the provisioner references var.instances_by_class (the real,
# known-after-apply instance IDs), which forces this resource AFTER instance
# creation/replacement - so the build can't race ahead of an in-flight rebuild (e.g.
# a `taint`). It then waits for each target instance to register Online with SSM
# before calling start-build, so the ansible-controller actually finds its targets
# rather than firing against a box that hasn't joined SSM yet. The scheduled run
# remains the backstop. Mirrors the manual command in outputs.tf ("Run Ansible Controller").
resource "null_resource" "trigger_ansible_controller" {
  count = local.ansible_controller_enabled && length(var.redeploy_triggers) > 0 ? 1 : 0

  # Any change to the set of class nonces (add/remove/bump) forces one new run.
  # Instance IDs are deliberately NOT in triggers - they gate ordering/readiness via
  # the provisioner below, but the redeploy switch alone decides WHEN to fire.
  triggers = {
    nonces = jsonencode(var.redeploy_triggers)
  }

  depends_on = [
    aws_codebuild_project.ansible_controller,
    aws_scheduler_schedule.ansible_controller,
  ]

  provisioner "local-exec" {
    # Referencing instance IDs here is what creates the dependency on the instances
    # (their IDs are known only after apply, so this provisioner is ordered after any
    # replacement). AWS_PROFILE is only set when non-empty so CI role auth isn't clobbered.
    environment = merge(
      {
        READY_INSTANCE_IDS = join(" ", flatten([for class_name, instances in var.instances_by_class : values(instances)]))
        AWS_REGION         = data.aws_region.current.id
        PROJECT_NAME       = aws_codebuild_project.ansible_controller[0].name
      },
      var.aws_profile != "" ? { AWS_PROFILE = var.aws_profile } : {}
    )

    # Wait (bounded) for each target instance to be Online in SSM, then start the build.
    command = <<-EOT
      set -u
      if [ -n "$READY_INSTANCE_IDS" ]; then
        for id in $READY_INSTANCE_IDS; do
          for attempt in $(seq 1 30); do
            status=$(aws ssm describe-instance-information --region "$AWS_REGION" \
              --filters "Key=InstanceIds,Values=$id" \
              --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
            if [ "$status" = "Online" ]; then
              echo "[redeploy] $id is Online in SSM"
              break
            fi
            echo "[redeploy] waiting for $id to register with SSM (attempt $attempt/30, status=$${status:-none})"
            sleep 10
          done
        done
      fi
      echo "[redeploy] starting ansible-controller build"
      aws codebuild start-build --region "$AWS_REGION" --project-name "$PROJECT_NAME"
    EOT
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
