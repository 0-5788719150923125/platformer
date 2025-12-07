# Deployment × tenant iteration model
# Each deployment is a named configuration (compute + RDS + ElastiCache + S3)
# Tenants are entitled to specific deployments via entitlements (e.g., "archshare.my-deployment")

locals {
  # Compute type per deployment
  compute_type_by_deployment = {
    for name, config in var.config :
    name => config.compute != null ? config.compute.type : "ec2"
  }

  # All deployment-tenant pairs (the fundamental iteration unit)
  deployment_tenants = flatten([
    for deploy_name, config in var.config : [
      for tenant in lookup(var.tenants_by_deployment, deploy_name, []) : {
        deployment = deploy_name
        tenant     = tenant
      }
    ]
  ])

  # Keyed by "deployment/tenant" for for_each usage
  deployment_tenant_map = {
    for dt in local.deployment_tenants :
    "${dt.deployment}/${dt.tenant}" => dt
  }

  # Split by compute type for different code paths (EC2 uses Ansible/SSM, EKS uses Helm)
  eks_deployment_tenants = {
    for key, dt in local.deployment_tenant_map :
    key => dt if local.compute_type_by_deployment[dt.deployment] == "eks"
  }

  ec2_deployment_tenants = {
    for key, dt in local.deployment_tenant_map :
    key => dt if local.compute_type_by_deployment[dt.deployment] == "ec2"
  }

  # All unique tenants across all deployments (for validation and outputs)
  all_tenants = distinct(flatten(values(var.tenants_by_deployment)))

  # Network selection per deployment (default to first available network)
  network_by_deployment = {
    for name, config in var.config :
    name => var.networks[coalesce(config.network, keys(var.networks)[0])]
  }

  # RDS cluster endpoints per deployment-tenant
  rds_endpoints = {
    for key, dt in local.deployment_tenant_map :
    key => {
      services_endpoint = try(var.rds_clusters["${dt.deployment}-${dt.tenant}-services"].endpoint, "")
      services_password = try(var.rds_clusters["${dt.deployment}-${dt.tenant}-services"].password, "")
      storage_endpoint  = try(var.rds_clusters["${dt.deployment}-${dt.tenant}-storage"].endpoint, "")
      storage_password  = try(var.rds_clusters["${dt.deployment}-${dt.tenant}-storage"].password, "")
    }
  }

  # ElastiCache cluster endpoints per deployment-tenant
  cache_endpoints = {
    for key, dt in local.deployment_tenant_map :
    key => {
      redis_services_endpoint = try(var.elasticache_clusters["${dt.deployment}-${dt.tenant}-services-cache"].endpoint, "")
      redis_storage_endpoint  = try(var.elasticache_clusters["${dt.deployment}-${dt.tenant}-storage-cache"].endpoint, "")
      memcached_endpoint      = try(var.elasticache_clusters["${dt.deployment}-${dt.tenant}-memcached"].endpoint, "")
    }
  }

  # S3 bucket names per deployment-tenant
  s3_buckets = {
    for key, dt in local.deployment_tenant_map :
    key => try(var.s3_buckets["${dt.deployment}-${dt.tenant}-images"], "")
  }

  # EFS filesystem IDs (shared across all deployments for now)
  efs_id = try(var.efs_filesystems["archshare-shared"].id, "")
}
