# Localhost Deployments
# Runs applications directly on the machine executing `terraform apply`
# No AWS infrastructure, no tenants, no security groups

locals {
  # Filter classes with type = "localhost"
  localhost_classes = {
    for class_name, class_config in var.config :
    class_name => class_config
    if class_config.type == "localhost"
  }

  # Flatten: class × application → deployment map keyed "{class}-{idx}"
  localhost_deployments = merge([
    for class_name, class_config in local.localhost_classes : {
      for idx, app in class_config.applications :
      "${class_name}-${idx}" => {
        class_name = class_name
        app_index  = idx
        type       = app.type
        script     = app.script
        params     = app.params
        playbook   = app.playbook
        playbook_file = coalesce(app.playbook_file, "playbook.yml")
      }
    }
  ]...)

  localhost_shell_deployments = {
    for key, deployment in local.localhost_deployments :
    key => deployment
    if deployment.type == "shell"
  }

  localhost_ansible_deployments = {
    for key, deployment in local.localhost_deployments :
    key => deployment
    if deployment.type == "ansible"
  }
}

# Shell deployments — backgrounded process, cleanup via STOP_CMD
resource "null_resource" "localhost_shell" {
  for_each = local.localhost_shell_deployments

  triggers = {
    config_hash  = md5(jsonencode(each.value))
    log_file     = abspath("${path.root}/.terraform/localhost/${each.key}.log")
    script_path  = abspath("${path.module}/scripts/localhost-process.sh")
    working_dir  = lookup(each.value.params, "WORKING_DIR", path.root)
    stop_command = lookup(each.value.params, "STOP_CMD", "true")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${self.triggers.script_path} ${self.triggers.log_file}"
    working_dir = lookup(each.value.params, "WORKING_DIR", null)
    environment = merge(each.value.params, {
      LOCALHOST_CMD = each.value.script
    })
  }

  # Application-level stop (e.g., docker compose down)
  provisioner "local-exec" {
    when        = destroy
    command     = self.triggers.stop_command
    working_dir = self.triggers.working_dir
    on_failure  = continue
  }
}

# Ansible deployments — run playbook with localhost inventory via local-exec
resource "null_resource" "localhost_ansible" {
  for_each = local.localhost_ansible_deployments

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      ansible-playbook \
        -i <(echo -e "[linux]\nlocalhost ansible_connection=local") \
        ${path.root}/applications/ansible/${each.value.playbook}/${each.value.playbook_file} \
        ${join(" ", [for k, v in each.value.params : "-e ${k}=${v}"])}
    EOT
  }

  triggers = {
    config_hash = md5(jsonencode(each.value))
  }
}
