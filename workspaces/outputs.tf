output "aws_profile" {
  description = "Resolved AWS profile for current workspace (from workspace file or default)"
  value       = local.resolved_aws_profile
}

output "aws_region" {
  description = "Resolved AWS region for current workspace (from workspace file or default)"
  value       = local.resolved_aws_region
}

output "owner" {
  description = "Resolved owner for current workspace (from workspace file or default)"
  value       = local.resolved_owner
}

output "states" {
  description = "Resolved state fragments list for current workspace (from workspace file or default)"
  value       = local.resolved_states
}

output "workspace" {
  description = "Current Terraform workspace name"
  value       = terraform.workspace
}

output "is_default_workspace" {
  description = "Whether currently using the default workspace (true = using base terraform.tfvars only)"
  value       = local.is_default_workspace
}

output "workspace_file_path" {
  description = "Path to workspace-specific tfvars file (may not exist)"
  value       = local.workspace_file_path
}

output "workspace_file_exists" {
  description = "Whether workspace-specific tfvars file exists"
  value       = local.workspace_file_exists
}
