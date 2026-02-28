# Pass-through outputs from hackathon-8 upstream module
# Commented out: upstream module is not bundled in this repo

# output "custom_domain_url" {
#   description = "HTTPS URL with custom domain"
#   value       = module.upstream.custom_domain_url
# }
#
# output "alb_dns_url" {
#   description = "Backup ALB DNS URL"
#   value       = module.upstream.alb_dns_url
# }
#
# output "studio_domain_url" {
#   description = "SageMaker Studio URL"
#   value       = module.upstream.studio_domain_url
# }
#
# output "notebook_instance_url" {
#   description = "SageMaker Notebook instance URL"
#   value       = module.upstream.notebook_instance_url
# }
#
# output "deployment_id" {
#   description = "Random pet name identifier for this deployment"
#   value       = module.upstream.deployment_id
# }
#
# output "aws_account_id" {
#   description = "AWS account ID"
#   value       = module.upstream.aws_account_id
# }
#
# output "aws_region" {
#   description = "AWS region"
#   value       = module.upstream.aws_region
# }
#
# output "s3_bucket_name" {
#   description = "S3 bucket name for notebooks, data, and models"
#   value       = module.upstream.s3_bucket_name
# }
#
# output "ecr_repository_urls" {
#   description = "ECR repository URLs map"
#   value       = module.upstream.ecr_repository_urls
# }
#
# output "ecr_login_command" {
#   description = "Docker login command for ECR"
#   value       = module.upstream.ecr_login_command
# }
#
# output "ssl_certificate_arn" {
#   description = "ACM certificate ARN"
#   value       = module.upstream.ssl_certificate_arn
# }
#
# output "inference_endpoints" {
#   description = "Map of deployed inference endpoints with details (name, ARN, URL)"
#   value       = module.upstream.inference_endpoints
# }
#
# output "codebuild_project_name" {
#   description = "CodeBuild project name for Docker image builds"
#   value       = module.upstream.codebuild_project_name
# }
#
# output "codebuild_console_url" {
#   description = "Console URL for monitoring CodeBuild"
#   value       = module.upstream.codebuild_console_url
# }
