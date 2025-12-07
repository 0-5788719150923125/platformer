# Dynamic Portal Action Generation from Command Registry
# Groups commands by category and generates one Port action per unique category
# V1 scope: Only commands with execution == "local" and non-empty action_config

locals {
  # Filter to portal-eligible commands (local execution with action_config)
  portal_commands = [
    for cmd in var.commands : cmd
    if cmd.execution == "local" && length(cmd.action_config) > 0
  ]

  # Group by category → one action per category
  portal_action_groups = { for cmd in local.portal_commands : cmd.category => cmd... }

  # Build action definitions
  dynamic_actions = {
    for category, cmds in local.portal_action_groups : category => {
      identifier     = replace(category, "-", "_")
      title          = cmds[0].title
      description    = cmds[0].description
      blueprint_type = cmds[0].blueprint_type
      targets        = distinct([for cmd in cmds : cmd.target])
      has_dropdown   = length(distinct([for cmd in cmds : cmd.target])) > 1
    }
  }

  # Generate action JSON definitions
  dynamic_action_jsons = {
    for category, action in local.dynamic_actions : category => jsonencode({
      identifier  = action.identifier
      title       = action.title
      icon        = "Microservice"
      description = action.description
      trigger = {
        type      = "self-service"
        operation = "DAY-2"
        userInputs = {
          properties = action.has_dropdown ? {
            target = {
              type        = "string"
              title       = "Target"
              description = "Select which target to run against"
              enum        = action.targets
              default = {
                jqQuery = (
                  action.blueprint_type == "service_url" ? ".entity.properties.module" :
                  action.blueprint_type == "storage" ? ".entity.properties.purpose" :
                  ".entity.properties.class"
                )
              }
            }
          } : {}
          required = action.has_dropdown ? ["target"] : []
        }
        blueprintIdentifier = (
          action.blueprint_type == "service_url" ? local.bp_service_url :
          action.blueprint_type == "storage" ? local.bp_storage :
          local.bp_compute_instance
        )
        # Only show this action on entities whose matching property is one of the command targets
        condition = {
          type       = "SEARCH"
          combinator = "and"
          rules = [
            {
              property = (
                action.blueprint_type == "service_url" ? "module" :
                action.blueprint_type == "storage" ? "purpose" :
                "class"
              )
              operator = "in"
              value    = action.targets
            }
          ]
        }
      }
      invocationMethod = {
        type         = "WEBHOOK"
        agent        = true
        url          = "http://action-handler:8080/webhook"
        method       = "POST"
        synchronized = false
        body = {
          action       = category
          resourceType = "run"
          context = {
            entity    = "{{ .entity.identifier }}"
            blueprint = "{{ .action.blueprint }}"
            runId     = "{{ .run.id }}"
          }
          payload = {
            entity = "{{ .entity }}"
            properties = action.has_dropdown ? {
              target = "{{ .inputs.target }}"
            } : {}
          }
        }
      }
      requiredApproval = false
    })
  }
}

# Write each action definition to a JSON file
# Not gated on is_subspace: actions use upsert semantics (POST then PUT on 409)
# so each workspace safely creates actions for its own commands without conflict.
resource "local_file" "dynamic_action_json" {
  for_each = local.dynamic_action_jsons

  content         = each.value
  filename        = "${path.module}/.terraform/action-${each.key}.json"
  file_permission = "0644"
}

# Manage dynamic action lifecycle via Port API
resource "null_resource" "dynamic_action" {
  for_each = local.dynamic_action_jsons

  triggers = {
    action_hash        = md5(each.value)
    script_path        = "${path.module}/scripts/manage-action.sh"
    action_file        = "${path.module}/.terraform/action-${each.key}.json"
    namespace          = var.namespace
    module_path        = path.module
    category           = each.key
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
    local_file.dynamic_action_json
  ]
}
