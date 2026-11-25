output "aws_profile" {
  description = "Resolved AWS profile for current workspace (from workspace file or default)"
  value       = local.resolved_aws_profile
}

output "aws_region" {
  description = "Resolved AWS region for current workspace (from workspace file or default)"
  value       = local.resolved_aws_region
}

output "oci_profile" {
  description = "Resolved OCI profile for current workspace (null = OCI not used)"
  value       = local.resolved_oci_profile
}

output "oci_region" {
  description = "Resolved OCI region for current workspace (null = region from the OCI profile)"
  value       = local.resolved_oci_region
}

output "optional_providers" {
  description = "Optional providers this workspace declares (beyond the always-on set), e.g. [\"oci\"]"
  value       = local.resolved_optional_providers
}

output "owner" {
  description = "Resolved owner for current workspace (from workspace file or default)"
  value       = local.resolved_owner
}

output "states" {
  description = "Resolved state fragments list for current workspace (from workspace file or default)"
  value       = local.resolved_states
}

output "states_paths" {
  description = "Resolved extra state fragment search paths for current workspace, as written (from workspace file or default)"
  value       = local.resolved_states_paths
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
