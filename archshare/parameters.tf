# SSM Parameter generation for Archshare
# Creates deployment-level parameters (not per-instance) with infrastructure endpoints
# Parameters contain tenant-specific RDS/cache endpoints for Ansible playbooks

locals {
  # Generate parameter map for each deployment-tenant pair (flattened for for_each)
  ssm_parameters = merge([
    for key, dt in local.deployment_tenant_map : {
      "${dt.deployment}-${dt.tenant}-rds-services-endpoint" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/rds/services/endpoint"
        value       = local.rds_endpoints[key].services_endpoint
        description = "RDS services database endpoint for ${dt.deployment}/${dt.tenant}"
        type        = "String"
      }
      "${dt.deployment}-${dt.tenant}-rds-services-password" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/rds/services/password"
        value       = local.rds_endpoints[key].services_password
        description = "RDS services database password for ${dt.deployment}/${dt.tenant}"
        type        = "SecureString"
      }
      "${dt.deployment}-${dt.tenant}-rds-storage-endpoint" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/rds/storage/endpoint"
        value       = local.rds_endpoints[key].storage_endpoint
        description = "RDS storage database endpoint for ${dt.deployment}/${dt.tenant}"
        type        = "String"
      }
      "${dt.deployment}-${dt.tenant}-rds-storage-password" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/rds/storage/password"
        value       = local.rds_endpoints[key].storage_password
        description = "RDS storage database password for ${dt.deployment}/${dt.tenant}"
        type        = "SecureString"
      }
      "${dt.deployment}-${dt.tenant}-redis-services" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/cache/redis-services/endpoint"
        value       = local.cache_endpoints[key].redis_services_endpoint
        description = "Redis services cache endpoint for ${dt.deployment}/${dt.tenant}"
        type        = "String"
      }
      "${dt.deployment}-${dt.tenant}-redis-storage" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/cache/redis-storage/endpoint"
        value       = local.cache_endpoints[key].redis_storage_endpoint
        description = "Redis storage cache endpoint for ${dt.deployment}/${dt.tenant}"
        type        = "String"
      }
      "${dt.deployment}-${dt.tenant}-memcached" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/cache/memcached/endpoint"
        value       = local.cache_endpoints[key].memcached_endpoint
        description = "Memcached endpoint for ${dt.deployment}/${dt.tenant}"
        type        = "String"
      }
      "${dt.deployment}-${dt.tenant}-s3-bucket" = {
        name        = "/${var.namespace}/${dt.deployment}/${dt.tenant}/s3/bucket"
        value       = local.s3_buckets[key]
        description = "S3 image storage bucket for ${dt.deployment}/${dt.tenant}"
        type        = "String"
      }
    }
  ]...)
}

# Create SSM parameters directly (deployment-level, not per-instance)
resource "aws_ssm_parameter" "archshare" {
  for_each = local.ssm_parameters

  name        = each.value.name
  description = each.value.description
  type        = each.value.type
  value       = each.value.value
  tier        = "Standard"

  tags = {
    Namespace = var.namespace
    Service   = "archshare"
  }
}
