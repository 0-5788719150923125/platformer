# Configuration Management outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "documents" {
  description = "Deployed SSM documents and their association schedules"
  value       = module.aws.documents
}

output "application_associations" {
  description = "Application associations created from applications module requests"
  value       = module.aws.application_associations
}

output "ansible_controller" {
  description = "Ansible controller CodeBuild project info"
  value       = module.aws.ansible_controller
}

output "ansible_playbooks_uploaded" {
  description = "Ansible playbook files uploaded to S3 by configuration-management"
  value       = module.aws.ansible_playbooks_uploaded
}

output "config" {
  description = "Configuration management service settings"
  value       = module.aws.config
}

output "trigger_execution" {
  description = "Commands to manually trigger association execution immediately (bypasses schedule)"
  value       = module.aws.trigger_execution
}

output "check_execution_status" {
  description = "Commands to view association execution history and status"
  value       = module.aws.check_execution_status
}

output "instance_parameters" {
  description = "Parameter Store definitions for EC2 instances (compute module creates resources)"
  value       = module.aws.instance_parameters
}

output "bucket_requests" {
  description = "S3 bucket definitions for storage module (storage module creates resources)"
  value       = module.aws.bucket_requests
}

output "patch_management_enabled" {
  description = "Whether patch management is enabled"
  value       = module.aws.patch_management_enabled
}

output "patch_management_summary" {
  description = "Summary of patch management configuration"
  value       = module.aws.patch_management_summary
}

output "patch_management_by_class" {
  description = "Per-class patch management configuration for portal scorecard"
  value       = module.aws.patch_management_by_class
}

output "baselines" {
  description = "Patch baselines with their class mappings"
  value       = module.aws.baselines
}

output "patch_groups_by_class" {
  description = "Map of class names to their namespaced patch group names for instance tagging"
  value       = module.aws.patch_groups_by_class
}

output "commands" {
  description = "Standardized operational commands for CLI display and portal actions"
  value       = module.aws.commands
}

output "docker_test_commands" {
  description = "Single command to test hybrid activation in Docker (run from terraform/ directory)"
  value       = module.aws.docker_test_commands
}

output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = module.aws.access_requests
}

output "event_bus_requests" {
  description = "Event bus webhook subscription requests (portal creates webhooks)"
  value       = module.aws.event_bus_requests
}
