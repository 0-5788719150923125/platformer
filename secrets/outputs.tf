# Secrets outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "replicated_secret_arns" {
  description = "Map of replicated secret name to local ARN"
  value       = module.aws.replicated_secret_arns
}

output "replicated_parameter_arns" {
  description = "Map of replicated parameter name to ARN"
  value       = module.aws.replicated_parameter_arns
}

output "replicated_parameter_names" {
  description = "Map of secret key to SSM parameter name"
  value       = module.aws.replicated_parameter_names
}
