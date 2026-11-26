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

output "fragments" {
  description = "Resolved fragments list for current workspace (from workspace file or default)"
  value       = local.resolved_fragments

  # The old names (renamed 2026-11-26) would otherwise be ignored, leaving the
  # workspace on the base fragments.
  precondition {
    condition     = !can(regex("(?m)^\\s*states(_paths)?\\s*=", local.workspace_file_no_comments))
    error_message = "${local.workspace_file_path} still sets `states` or `states_paths`: they are now `fragments` and `fragment_paths`."
  }
}

output "fragment_paths" {
  description = "Resolved extra fragment search paths for current workspace, as written (from workspace file or default)"
  value       = local.resolved_fragment_paths
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
