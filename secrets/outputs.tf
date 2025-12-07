output "replicated_secret_arns" {
  description = "Map of replicated secret name to local ARN"
  value       = { for k, v in aws_secretsmanager_secret.replicated : k => v.arn }
}

output "replicated_parameter_arns" {
  description = "Map of replicated parameter name to ARN"
  value       = { for k, v in aws_ssm_parameter.replicated : k => v.arn }
}

output "replicated_parameter_names" {
  description = "Map of secret key to SSM parameter name"
  value       = { for k, v in aws_ssm_parameter.replicated : k => v.name }
}
