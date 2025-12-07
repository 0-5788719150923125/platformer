# Dependency inversion interfaces - export requests for storage and compute modules

output "rds_cluster_requests" {
  description = "RDS cluster requests for storage module (SQL Server standalone instances)"
  value       = local.rds_cluster_requests
}

output "bucket_requests" {
  description = "S3 bucket requests for storage module"
  value       = local.bucket_requests
}

# Export ECS cluster definitions for compute module
# Each deployment gets one ECS cluster (purpose: "${deployment}-io")
output "compute_class_requests" {
  description = "ECS cluster definitions for compute module (deployment name = cluster class name)"
  value = {
    for deploy_name, config in var.config :
    "${deploy_name}-io" => {
      type               = "ecs"
      container_insights = true
      description        = "ArchOrchestrator deployment ${deploy_name}"
      tags = {
        Deployment = deploy_name
        ManagedBy  = "platformer-archorchestrator"
      }
    }
  }
}

# Export configuration for debugging/visibility
output "config" {
  description = "ArchOrchestrator configuration summary"
  value = {
    tenants      = local.all_tenants
    tenant_count = length(local.all_tenants)
    deployments  = keys(var.config)
    rds_enabled  = local.rds_enabled
    s3_enabled   = local.s3_enabled
  }
}

# Access: IAM access requests (dependency inversion - access creates IAM resources)
# IMPORTANT: This output must be purely config/variable-derived (no module-internal resources)
# to avoid Terraform module-closure cycles. Local inline policies referencing module resources
# (e.g., aws_ecr_repository.main.arn) stay in iam.tf instead.
output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = local.access_requests
}

# Access: Security Groups (dependency inversion interface for access module)
output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = local.access_security_groups
}

# ALB URLs (user-friendly output for accessing deployed services)
output "alb_urls" {
  description = "ALB DNS names per deployment (use these to access services)"
  value = {
    for name, lb in aws_lb.main :
    name => "http://${lb.dns_name}"
  }
}

# ECS cluster ARNs (for monitoring/debugging)
output "ecs_clusters" {
  description = "ECS cluster ARNs per deployment"
  value = {
    for deploy_name in keys(var.config) :
    deploy_name => var.ecs_clusters["${deploy_name}-io"].arn
  }
}

