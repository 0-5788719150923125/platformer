# Dependency inversion interfaces - export requests for other modules

# Compute class definitions for the compute module
# Each deployment's compute classes are prefixed with the deployment name
# e.g., deployment "ec2-poc" with class "depot" emits "ec2-poc-depot"
output "compute_class_requests" {
  description = "Compute class definitions for the compute module (prefixed with deployment name)"
  value = merge([
    for deploy_name, config in var.config : {
      for class_name, class_config in coalesce(config.compute, {}) :
      "${deploy_name}-${class_name}" => merge(class_config, {
        # Inject shared Maestro SSH security group for PACS deployments
        security_group_ids = concat(
          coalesce(class_config.security_group_ids, []),
          config.maestro != null ? [aws_security_group.maestro_ssh[deploy_name].id] : []
        )
      })
    }
  ]...)
}

output "rds_cluster_requests" {
  description = "RDS Aurora cluster requests for storage module"
  value       = local.rds_cluster_requests
}

output "bucket_requests" {
  description = "S3 bucket requests for storage module"
  value       = local.bucket_requests
}

output "elasticache_cluster_requests" {
  description = "ElastiCache cluster requests for storage module (future)"
  value       = []
}

# Export configuration for debugging/visibility
output "config" {
  description = "ArchPACS configuration summary"
  value = {
    tenants      = local.all_tenants
    tenant_count = length(local.all_tenants)
    deployments  = keys(var.config)
    rds_enabled  = local.rds_enabled
    s3_enabled   = local.s3_enabled
  }
}

# Access: Security Groups (dependency inversion interface for access module)
output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = local.access_security_groups
}

# Maestro metadata for applications module routing
output "maestro" {
  description = "Maestro configuration per deployment (for bootstrap playbook parameterization)"
  value = {
    for deploy_name, maestro_config in local.maestro_deployments : deploy_name => {
      pacs_version       = maestro_config.pacs_version
      iv_version         = coalesce(maestro_config.iv_version, maestro_config.pacs_version)
      orchestrator_class = maestro_config.orchestrator_class
      client_code        = maestro_config.client_code
      password_ssm_path  = aws_ssm_parameter.maestro_deploy_password[deploy_name].name
    }
  }
}
