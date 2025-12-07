# Archshare Module
# Domain orchestration for Archshare medical imaging platform
# Generates infrastructure requests (RDS, ElastiCache, S3) for storage module via dependency inversion
# Supports multi-deployment, multi-tenant configurations

# RDS Cluster Requests (services + storage, per deployment × tenant)
locals {
  rds_cluster_requests = flatten([
    for deploy_name, config in var.config : [
      for tenant_code in lookup(var.tenants_by_deployment, deploy_name, []) : [
        {
          type                    = "aurora"
          name                    = "${var.namespace}-${deploy_name}-${tenant_code}-services"
          purpose                 = "${deploy_name}-${tenant_code}-services"
          database_name           = "v3s"
          engine_version          = config.rds.services.engine_version
          instance_class          = config.rds.services.instance_class
          instances               = config.rds.services.instances
          deletion_protection     = false # Dev: disabled
          backup_retention_period = 1     # Dev: 1 day
          final_snapshot          = false # Dev: no final snapshot
          subnet_ids              = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
          vpc_id                  = local.network_by_deployment[deploy_name].network_summary.vpc_id
        },
        {
          type                    = "aurora"
          name                    = "${var.namespace}-${deploy_name}-${tenant_code}-storage"
          purpose                 = "${deploy_name}-${tenant_code}-storage"
          database_name           = "imagedb"
          engine_version          = config.rds.storage.engine_version
          instance_class          = config.rds.storage.instance_class
          instances               = config.rds.storage.instances
          deletion_protection     = false
          backup_retention_period = 1
          final_snapshot          = false
          subnet_ids              = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
          vpc_id                  = local.network_by_deployment[deploy_name].network_summary.vpc_id
        }
      ]
    ] if config.rds != null
  ])
}

# ElastiCache Cluster Requests (Valkey services, Valkey storage, Memcached, per deployment × tenant)
locals {
  elasticache_cluster_requests = flatten([
    for deploy_name, config in var.config : [
      for tenant_code in lookup(var.tenants_by_deployment, deploy_name, []) : [
        {
          purpose                    = "${deploy_name}-${tenant_code}-services-cache"
          engine                     = config.elasticache.services.engine
          engine_version             = config.elasticache.services.engine_version
          node_type                  = config.elasticache.services.node_type
          num_cache_nodes            = config.elasticache.services.num_cache_nodes
          transit_encryption_enabled = config.elasticache.services.transit_encryption_enabled
          subnet_ids                 = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
          vpc_id                     = local.network_by_deployment[deploy_name].network_summary.vpc_id
        },
        {
          purpose                    = "${deploy_name}-${tenant_code}-storage-cache"
          engine                     = config.elasticache.storage.engine
          engine_version             = config.elasticache.storage.engine_version
          node_type                  = config.elasticache.storage.node_type
          num_cache_nodes            = config.elasticache.storage.num_cache_nodes
          transit_encryption_enabled = config.elasticache.storage.transit_encryption_enabled
          subnet_ids                 = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
          vpc_id                     = local.network_by_deployment[deploy_name].network_summary.vpc_id
        },
        {
          purpose                    = "${deploy_name}-${tenant_code}-memcached"
          engine                     = "memcached"
          engine_version             = config.elasticache.memcached.engine_version
          node_type                  = config.elasticache.memcached.node_type
          num_cache_nodes            = config.elasticache.memcached.num_cache_nodes
          transit_encryption_enabled = config.elasticache.memcached.transit_encryption_enabled
          subnet_ids                 = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
          vpc_id                     = local.network_by_deployment[deploy_name].network_summary.vpc_id
        }
      ]
    ] if config.elasticache != null
  ])
}

# S3 Bucket Requests (image storage, per deployment × tenant)
locals {
  bucket_requests = flatten([
    for deploy_name, config in var.config : [
      for tenant_code in lookup(var.tenants_by_deployment, deploy_name, []) : [
        {
          purpose            = "${deploy_name}-${tenant_code}-images"
          description        = "Archshare DICOM image storage for ${deploy_name}/${tenant_code}"
          prefix             = "${tenant_code}-dev"
          versioning_enabled = false # Dev: disabled
          force_destroy      = true  # Dev: allow destroy with objects
        }
      ]
    ]
  ])
}
