# Access outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "iam_role_arns" {
  description = "IAM role ARNs keyed by module-purpose (return path to consuming modules)"
  value       = module.aws.iam_role_arns
}

output "iam_role_names" {
  description = "IAM role names keyed by module-purpose (return path to consuming modules)"
  value       = module.aws.iam_role_names
}

output "instance_profile_names" {
  description = "Instance profile names keyed by module-purpose (return path to consuming modules)"
  value       = module.aws.instance_profile_names
}

output "instance_profile_arns" {
  description = "Instance profile ARNs keyed by module-purpose (return path to consuming modules)"
  value       = module.aws.instance_profile_arns
}

output "bucket_requests" {
  description = "S3 bucket request for access report storage (dependency inversion to storage module)"
  value       = module.aws.bucket_requests
}

output "report_ready" {
  description = "Opaque dependency handle - changes whenever the access report is rewritten. Pass to null_resource triggers to guarantee the file exists before use."
  value       = module.aws.report_ready
}

output "artifact_requests" {
  description = "Artifact registry entry for the access control report (dependency inversion to portal)"
  value       = module.aws.artifact_requests
}

output "report_path" {
  description = "Local filesystem path to the generated JSON access report"
  value       = module.aws.report_path
}

output "access_summary" {
  description = "Summary of access control policies by module"
  value       = module.aws.access_summary
}
