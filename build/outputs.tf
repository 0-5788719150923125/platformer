# Build outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "built_amis" {
  description = "Map of class name to golden AMI ID built by Packer"
  value       = local.aws_output_built_amis
}

output "artifact_requests" {
  description = "Artifact registry entries for built golden AMIs (dependency inversion to portal)."
  value       = local.aws_output_artifact_requests
}

output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = local.aws_output_access_requests
}

output "commands" {
  description = "Packer build commands for CLI display and portal actions"
  value       = local.aws_output_commands
}
