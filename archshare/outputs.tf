# Dependency inversion interfaces - export requests for storage module

output "rds_cluster_requests" {
  description = "RDS Aurora cluster requests for storage module"
  value       = local.rds_cluster_requests
}

output "elasticache_cluster_requests" {
  description = "ElastiCache cluster requests for storage module"
  value       = local.elasticache_cluster_requests
}

output "bucket_requests" {
  description = "S3 bucket requests for storage module"
  value       = local.bucket_requests
}

# Export compute class definitions for the compute module
# Each deployment name becomes a compute class name
output "compute_class_requests" {
  description = "Compute class definitions for the compute module (deployment name = class name)"
  value = {
    for name, config in var.config :
    name => config.compute
    if config.compute != null
  }
}

# Export configuration for other modules
output "config" {
  description = "Archshare configuration summary"
  value = {
    tenants       = local.all_tenants
    tenant_count  = length(local.all_tenants)
    deployments   = keys(var.config)
    rds_enabled   = anytrue([for _, config in var.config : config.rds != null])
    cache_enabled = anytrue([for _, config in var.config : config.elasticache != null])
  }
}

# Export storage endpoints (for debugging/visibility, organized by deployment/tenant)
output "storage_endpoints" {
  description = "Storage backend endpoints per deployment-tenant"
  value = {
    for key, dt in local.deployment_tenant_map :
    key => {
      rds_services   = local.rds_endpoints[key].services_endpoint
      rds_storage    = local.rds_endpoints[key].storage_endpoint
      redis_services = local.cache_endpoints[key].redis_services_endpoint
      redis_storage  = local.cache_endpoints[key].redis_storage_endpoint
      memcached      = local.cache_endpoints[key].memcached_endpoint
      s3_bucket      = local.s3_buckets[key]
    }
  }
  sensitive = true
}

# Export ansible playbook bucket request
output "ansible_bucket_request" {
  description = "Bucket request for Ansible playbooks"
  value = {
    purpose     = "archshare-ansible-playbooks"
    description = "Ansible playbooks for Archshare deployment"
    prefix      = "archshare"
  }
}

# Export Helm application requests for EKS deployments
output "helm_application_requests" {
  description = "Helm chart deployment requests for EKS compute"
  value       = local.helm_requests
}

# Export EKS deployment-tenant pairs (for root module's archshare_urls output)
output "eks_deployment_tenants" {
  description = "EKS deployment-tenant pairs for URL generation"
  value       = local.eks_deployment_tenants
}

# Export frontend service URLs (LoadBalancer hostnames from Kubernetes)
output "frontend_service_urls" {
  description = "Frontend service LoadBalancer URLs per deployment-tenant"
  value = {
    for key, dt in local.eks_deployment_tenants :
    key => try(data.external.frontend_service_url[key].result.hostname, null)
  }
  depends_on = [data.external.frontend_service_url]
}
