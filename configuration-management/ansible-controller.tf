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
# Force reboot (state-file `reboot` switch)
# ========================================
# A compute class's `reboot` switch (true / false / "<nonce>") flows in via
# var.reboot_triggers. A change to that map replaces this resource and hard
# stop/starts the class's instances. We deliberately use `stop-instances --force`
# + `start-instances` rather than `reboot-instances`: the latter is only an ACPI
# request that an OOM-hung box ignores (AWS falls back to a hard reboot after ~4
# minutes); a forced stop is the guaranteed immediate path. `reboot: true` carries
# a per-apply value, so the instances reboot on EVERY apply (expect a standing plan
# diff); a "<nonce>" string reboots only when it changes.
#
# Ordering: referencing var.instances_by_class orders this AFTER instance
# creation/replacement, and null_resource.trigger_ansible_controller depends_on
# this resource (and includes the reboot nonces in its triggers), so the
# ansible-controller build always fires AFTER the reboot - never against a box
# mid-stop. Note: a stop/start releases any auto-assigned public IP; ALB targeting
# and SSM are instance-ID based, so deployments are unaffected.
resource "null_resource" "force_reboot" {
  count = length(var.reboot_triggers) > 0 ? 1 : 0

  # Any change to the set of class nonces (add/remove/bump) forces one new reboot.
  triggers = {
    nonces = jsonencode(var.reboot_triggers)
  }

  provisioner "local-exec" {
    # Only instances of classes present in reboot_triggers are rebooted.
    # Referencing instance IDs creates the dependency on the instances themselves.
    environment = merge(
      {
        REBOOT_INSTANCE_IDS = join(" ", flatten([
          for class_name, instances in var.instances_by_class :
          values(instances) if contains(keys(var.reboot_triggers), class_name)
        ]))
        AWS_REGION = data.aws_region.current.id
      },
      var.aws_profile != "" ? { AWS_PROFILE = var.aws_profile } : {}
    )

    # Force-stop (hard power-off), then start. An OOM-hung box can wedge in the
    # "stopping" state even after one forced stop - AWS only escalates to a hard
    # power-off when stop-instances --force is issued AGAIN while already stopping.
    # So instead of a blind `aws ec2 wait instance-stopped` (which sits for up to
    # 10 minutes without ever re-forcing), poll the state and re-issue the forced
    # stop every 30s until the instance actually reaches "stopped".
    command = <<-EOT
      set -u
      if [ -z "$REBOOT_INSTANCE_IDS" ]; then
        echo "[reboot] no instances to reboot"
        exit 0
      fi
      echo "[reboot] force-stopping: $REBOOT_INSTANCE_IDS"
      aws ec2 stop-instances --region "$AWS_REGION" --force --instance-ids $REBOOT_INSTANCE_IDS >/dev/null
      for attempt in $(seq 1 40); do
        states=$(aws ec2 describe-instances --region "$AWS_REGION" \
          --instance-ids $REBOOT_INSTANCE_IDS \
          --query 'Reservations[].Instances[].State.Name' --output text)
        if ! echo "$states" | grep -qv stopped; then
          echo "[reboot] all instances stopped"
          break
        fi
        echo "[reboot] waiting for stop (attempt $attempt/40, states: $states)"
        # Re-issue the forced stop every 30s - a second --force while an instance
        # is in "stopping" is what escalates AWS to a hard power-off.
        if [ $((attempt % 2)) -eq 0 ]; then
          echo "[reboot] re-issuing forced stop"
          aws ec2 stop-instances --region "$AWS_REGION" --force --instance-ids $REBOOT_INSTANCE_IDS >/dev/null || true
        fi
        sleep 15
      done
      echo "[reboot] starting: $REBOOT_INSTANCE_IDS"
      aws ec2 start-instances --region "$AWS_REGION" --instance-ids $REBOOT_INSTANCE_IDS >/dev/null
      aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids $REBOOT_INSTANCE_IDS
      echo "[reboot] all instances running"
    EOT
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
  count = local.ansible_controller_enabled && (length(var.redeploy_triggers) > 0 || length(var.reboot_triggers) > 0) ? 1 : 0

  # Any change to the set of class nonces (add/remove/bump) forces one new run.
  # Reboot nonces are included so a forced reboot is always followed by a build.
  # Instance IDs are deliberately NOT in triggers - they gate ordering/readiness via
  # the provisioner below, but the redeploy/reboot switches alone decide WHEN to fire.
  triggers = {
    nonces        = jsonencode(var.redeploy_triggers)
    reboot_nonces = jsonencode(var.reboot_triggers)
  }

  depends_on = [
    aws_codebuild_project.ansible_controller,
    aws_scheduler_schedule.ansible_controller,
    # Reboot BEFORE build: the SSM-Online wait below then confirms the rebooted
    # boxes are back before start-build fires.
    null_resource.force_reboot,
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

    # Wait (bounded) for each target instance to be Online in SSM, start the build,
    # then BLOCK on it: stream the build's CloudWatch logs into the apply output and
    # propagate the result - a FAILED ansible run fails the terraform apply instead
    # of silently fire-and-forgetting.
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
      BUILD_ID=$(aws codebuild start-build --region "$AWS_REGION" --project-name "$PROJECT_NAME" \
        --query 'build.id' --output text)
      echo "[redeploy] build started: $BUILD_ID"
      LOG_GROUP="/aws/codebuild/$PROJECT_NAME"
      LOG_STREAM="$${BUILD_ID#*:}"   # log stream name is the UUID after "project:"
      echo "[redeploy] streaming logs from $LOG_GROUP ($LOG_STREAM)"

      # Fetch-and-print new log events since the last call. Polled inline rather
      # than `aws logs tail --follow` in the background: the CLI block-buffers
      # stdout when piped (local-exec is a pipe), so a backgrounded tail shows
      # nothing until exit. get-log-events with a forward token is unbuffered and
      # exact - each call returns only events after the previous token.
      NEXT_TOKEN=""
      EVENTS_TMP=$(mktemp)
      trap 'rm -f "$EVENTS_TMP"' EXIT
      fetch_logs() {
        if aws logs get-log-events --region "$AWS_REGION" \
            --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM" \
            --start-from-head $${NEXT_TOKEN:+--next-token $NEXT_TOKEN} \
            --output json > "$EVENTS_TMP" 2>/dev/null; then
          python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(e["message"].rstrip()) for e in d["events"]]' "$EVENTS_TMP"
          NEXT_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nextForwardToken"])' "$EVENTS_TMP")
        fi
      }

      # Poll the build to completion, printing new logs each pass; only
      # SUCCEEDED lets the apply pass.
      while true; do
        fetch_logs
        status=$(aws codebuild batch-get-builds --region "$AWS_REGION" --ids "$BUILD_ID" \
          --query 'builds[0].buildStatus' --output text 2>/dev/null || echo UNKNOWN)
        case "$status" in
          IN_PROGRESS|UNKNOWN) sleep 10 ;;
          SUCCEEDED)
            sleep 5; fetch_logs   # flush the final lines
            echo "[redeploy] build SUCCEEDED: $BUILD_ID"
            exit 0 ;;
          *)
            sleep 5; fetch_logs
            echo "[redeploy] build finished with status $status: $BUILD_ID" >&2
            echo "[redeploy] full logs: aws logs tail '$LOG_GROUP' --region $AWS_REGION --log-stream-name-prefix '$LOG_STREAM'" >&2
            exit 1 ;;
        esac
      done
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
