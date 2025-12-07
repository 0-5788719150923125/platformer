# Port Agent and Action Handler via Docker Compose
# Manages long-running services for executing Port self-service actions

# Temporary env file for sensitive credentials (cleaned up by script after use)
resource "local_file" "port_agent_env" {
  content = <<-EOT
    PORT_ORG_ID=${var.port_org_id}
    PORT_CLIENT_ID=${var.port_client_id}
    PORT_CLIENT_SECRET=${var.port_secret}
  EOT

  filename        = "${path.module}/.terraform/port-agent-${var.namespace}.env"
  file_permission = "0600"

  # This file is consumed and deleted by manage-docker-compose.sh after use.
  # Ignore the missing file on subsequent plans to avoid recreating it.
  lifecycle {
    ignore_changes = all
  }
}

# Commands registry JSON for action handler (per-workspace to support multi-workspace merging)
resource "local_file" "commands_json" {
  content         = jsonencode(var.commands)
  filename        = "${path.module}/port-agent/commands.d/${terraform.workspace}.json"
  file_permission = "0644"
}

resource "null_resource" "port_agent" {
  # Trigger recreation if namespace, configuration, or application files change
  triggers = {
    namespace           = var.namespace
    compose_path        = "${path.module}/port-agent"
    script_path         = "${path.module}/scripts/manage-docker-compose.sh"
    aws_region          = data.aws_region.current.id
    aws_profile         = var.aws_profile
    commands_hash       = md5(jsonencode(var.commands))
    terraform_workspace = terraform.workspace
    # Track action handler application files
    app_py_hash       = filemd5("${path.module}/port-agent/action-handler/app.py")
    dockerfile_hash   = filemd5("${path.module}/port-agent/action-handler/Dockerfile")
    requirements_hash = filemd5("${path.module}/port-agent/action-handler/requirements.txt")
    compose_yml_hash  = filemd5("${path.module}/port-agent/compose.yml")
  }

  # Start Docker Compose services
  provisioner "local-exec" {
    command = <<-EOT
      ${self.triggers.script_path} up ${self.triggers.compose_path} ${self.triggers.namespace} ${local_file.port_agent_env.filename} \
        NAMESPACE=${self.triggers.namespace} \
        AWS_PROFILE=${self.triggers.aws_profile} \
        AWS_REGION=${self.triggers.aws_region} \
        TERRAFORM_WORKSPACE=${self.triggers.terraform_workspace}
    EOT
  }

  # Stop and remove Docker Compose services on destroy
  provisioner "local-exec" {
    when       = destroy
    command    = "${self.triggers.script_path} down ${self.triggers.compose_path} ${self.triggers.namespace}"
    on_failure = continue
  }

  depends_on = [
    local_file.port_agent_env,
    local_file.commands_json
  ]
}

# Temporary env file for Port API credentials (used by action management)
resource "local_file" "port_action_env" {
  content = <<-EOT
    PORT_CLIENT_ID=${var.port_client_id}
    PORT_CLIENT_SECRET=${var.port_secret}
  EOT

  filename        = "${path.module}/.terraform/port-action-${var.namespace}.env"
  file_permission = "0600"

  lifecycle {
    ignore_changes = all
  }
}

# Port self-service action lifecycle management
# Generate action definition with namespaced blueprint identifier
resource "local_file" "port_action_definition" {
  content = jsonencode({
    identifier  = "run_command"
    title       = "Run Command"
    icon        = "Terminal"
    description = "Execute a shell command on an EC2 instance via AWS SSM"
    trigger = {
      type      = "self-service"
      operation = "DAY-2"
      userInputs = {
        properties = {
          command = {
            type        = "string"
            title       = "Command"
            description = "Shell command to execute on the instance"
            default     = "echo 'hello world'"
          }
        }
        required = []
      }
      blueprintIdentifier = local.bp_compute_instance
    }
    invocationMethod = {
      type         = "WEBHOOK"
      agent        = true
      url          = "http://action-handler:8080/webhook"
      method       = "POST"
      synchronized = false
      body = {
        action       = "{{ .action.identifier }}"
        resourceType = "run"
        context = {
          entity    = "{{ .entity.identifier }}"
          blueprint = "{{ .action.blueprint }}"
          runId     = "{{ .run.id }}"
        }
        payload = {
          entity = "{{ .entity }}"
          properties = {
            command = "{{ .inputs.command }}"
          }
        }
      }
    }
    requiredApproval = false
  })
  filename = "${path.module}/.terraform/port-action-definition-${var.namespace}.json"
}

resource "null_resource" "port_action" {
  count = local.is_subspace ? 0 : 1
  triggers = {
    action_definition  = local_file.port_action_definition.content_md5
    script_path        = "${path.module}/scripts/manage-action.sh"
    action_file        = local_file.port_action_definition.filename
    namespace          = var.namespace
    module_path        = path.module
    action_permissions = local.action_permissions_json
  }

  # Create/update action
  provisioner "local-exec" {
    command = "${self.triggers.script_path} create ${self.triggers.action_file} ${local_file.port_action_env.filename} '${self.triggers.action_permissions}'"
  }

  # Delete action on destroy
  provisioner "local-exec" {
    when       = destroy
    command    = "${self.triggers.script_path} destroy ${self.triggers.action_file} ${self.triggers.module_path}/.terraform/port-action-${self.triggers.namespace}.env"
    on_failure = continue
  }

  depends_on = [
    null_resource.port_agent,
    local_file.port_action_env,
    local_file.port_action_definition
  ]
}

# Output action handler URL for reference
output "action_handler_url" {
  description = "URL where Port agent forwards webhooks"
  value       = "http://action-handler:8080/webhook"
}

output "action_handler_health_url" {
  description = "Health check URL for action handler (from host)"
  value       = "http://localhost:8080/health"
}
