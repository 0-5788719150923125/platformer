# Application deployments via SSM (ssm and compose requests)
#
# Each request gets its own SSM Command document with the script, its
# parameters and its environment embedded (base64, so nothing in them is read
# as an SSM {{ placeholder }}), and a State Manager association that runs it
# every 30 minutes and whenever the document changes.
#
# Why embedded rather than downloaded from S3: it works on any SSM-managed
# Linux host, EC2 or hybrid (mi-), with no aws CLI, no instance-role S3
# permissions and no bucket. Hybrid hosts on the standard tier support Run
# Command (this) but not Session Manager, so the Ansible controller can't
# reach them.
#
# Delivery on the host:
#   - params      exported as environment variables
#   - environment written as KEY='value' lines to $APP_ENV_FILE
#                 (compose-stack.sh installs it as the project's .env)
#   - APP_ACTION  "up", or "down" for teardown
#
# Requests with `teardown = true` (compose) also get a terraform_data whose
# destroy-time provisioner runs the document with action=down, so removing a
# stack from state removes it from its hosts.

locals {
  # Targets per request, by targeting mode
  ssm_application_targets = {
    for key, req in local.ssm_application_requests : key => (
      coalesce(req.targeting_mode, "compute") == "instance" ? [
        { key = "InstanceIds", values = [req.instance_id] }
      ] :
      coalesce(req.targeting_mode, "compute") == "tags" ? [
        for t in coalesce(req.targets, []) : { key = t.key, values = t.values }
      ] :
      coalesce(req.targeting_mode, "compute") == "compute" ? concat(
        [{ key = "tag:${req.target_tag_key}", values = [req.target_tag_value] }],
        req.tenant != null ? [{ key = "tag:Tenant", values = [req.tenant] }] : []
      ) :
      [{ key = "InstanceIds", values = ["*"] }] # wildcard
    )
  }

  # .env-style files: KEY='value', sorted. Single-quoted values are literal in
  # both docker compose and sh, so neither interpolates `$`. Values can't hold
  # a single quote or a line break (checked by the document's precondition).
  ssm_application_env_files = {
    for key, req in local.ssm_application_requests : key => join("", [
      for k in sort(keys(coalesce(req.environment, {}))) : "${k}='${req.environment[k]}'\n"
    ])
  }

  # Script parameters, as sh assignments (sourced with `set -a`)
  ssm_application_param_files = {
    for key, req in local.ssm_application_requests : key => join("", [
      for k in sort(keys(coalesce(req.params, {}))) : "${k}='${replace(req.params[k], "'", "'\\''")}'\n"
    ])
  }

  ssm_application_documents = {
    for key, req in local.ssm_application_requests : key => {
      schemaVersion = "2.2"
      description   = "Platformer application ${key} (${req.type}: ${req.script})"
      parameters = {
        action = {
          type          = "String"
          description   = "up deploys or converges; down tears down (scripts that support it)"
          default       = "up"
          allowedValues = ["up", "down"]
        }
      }
      mainSteps = [
        {
          action       = "aws:runShellScript"
          name         = "run"
          precondition = { StringEquals = ["platformType", "Linux"] }
          inputs = {
            timeoutSeconds = "3600"
            runCommand = [
              "set -eu",
              "work=$(mktemp -d)",
              "trap 'rm -rf \"$work\"' EXIT",
              "echo '${base64encode(file(req.script_source_path))}' | base64 -d > \"$work/run\"",
              "echo '${base64encode(local.ssm_application_param_files[key])}' | base64 -d > \"$work/params\"",
              "echo '${base64encode(local.ssm_application_env_files[key])}' | base64 -d > \"$work/env\"",
              "set -a; . \"$work/params\"; set +a",
              "export APP_ACTION='{{ action }}' APP_ENV_FILE=\"$work/env\"",
              "bash \"$work/run\"",
            ]
          }
        }
      ]
    }
  }
}

resource "aws_ssm_document" "applications" {
  for_each = local.ssm_application_requests

  name            = "app-${each.key}-${var.namespace}"
  document_type   = "Command"
  document_format = "JSON"
  content         = jsonencode(local.ssm_application_documents[each.key])

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }

  lifecycle {
    precondition {
      condition = alltrue([
        for k, v in coalesce(each.value.environment, {}) :
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !can(regex("['\\n\\r]", v))
      ])
      error_message = "Application ${each.key}: environment keys must be shell-style names, and values can't contain a single quote or a line break."
    }
  }
}

resource "aws_ssm_association" "applications" {
  for_each = local.ssm_application_requests

  name             = aws_ssm_document.applications[each.key].name
  association_name = "app-${each.key}-${var.namespace}"
  # Pinning the version makes every document change an association update,
  # and State Manager runs an association as soon as it is updated.
  document_version    = aws_ssm_document.applications[each.key].default_version
  schedule_expression = "rate(30 minutes)"

  dynamic "targets" {
    for_each = local.ssm_application_targets[each.key]
    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  # compose: roll out one host at a time and stop at the first failure, so a
  # bad commit or setting leaves the other hosts on the previous version.
  max_concurrency = each.value.type == "compose" ? "1" : null
  max_errors      = each.value.type == "compose" ? "0" : null

  compliance_severity = "MEDIUM"

  # Destroy order: the association goes first (no more scheduled `up`), then
  # the teardown runs, then the document is deleted.
  depends_on = [terraform_data.application_teardown]
}

# Teardown on removal: runs the document with action=down against the same
# targets and waits for it. Replaced (old targets torn down) when the targets
# change. If a host is unreachable the destroy fails; once the stack is gone
# some other way, drop the resource with `terraform state rm`.
resource "terraform_data" "application_teardown" {
  for_each = {
    for key, req in local.ssm_application_requests : key => req
    if coalesce(req.teardown, false)
  }

  triggers_replace = local.ssm_application_targets[each.key]

  input = {
    region   = data.aws_region.current.region
    profile  = var.aws_profile
    document = aws_ssm_document.applications[each.key].name
    targets = jsonencode([
      for t in local.ssm_application_targets[each.key] : { Key = t.key, Values = t.values }
    ])
  }

  provisioner "local-exec" {
    when = destroy

    environment = merge(
      {
        AWS_REGION = self.input.region
        DOCUMENT   = self.input.document
        TARGETS    = self.input.targets
      },
      self.input.profile != "" ? { AWS_PROFILE = self.input.profile } : {}
    )

    command = <<-EOT
      set -eu
      echo "[teardown] $DOCUMENT -> $TARGETS"
      CMD=$(aws ssm send-command --region "$AWS_REGION" --document-name "$DOCUMENT" \
        --parameters action=down --targets "$TARGETS" --timeout-seconds 600 \
        --comment "platformer teardown" --query Command.CommandId --output text)
      for attempt in $(seq 1 120); do
        STATUS=$(aws ssm list-commands --region "$AWS_REGION" --command-id "$CMD" \
          --query 'Commands[0].Status' --output text)
        case "$STATUS" in
          Pending|InProgress|Cancelling) sleep 10 ;;
          *) break ;;
        esac
      done
      aws ssm list-command-invocations --region "$AWS_REGION" --command-id "$CMD" --details \
        --query 'CommandInvocations[].[InstanceId,Status,CommandPlugins[0].Output]' --output text
      if [ "$STATUS" != "Success" ]; then
        echo "[teardown] command $CMD finished with status $STATUS" >&2
        echo "[teardown] if the host is gone, remove this resource with terraform state rm" >&2
        exit 1
      fi
      echo "[teardown] done"
    EOT
  }
}
