# Bucket inventory (keyed by purpose)
output "buckets" {
  description = "S3 buckets created from bucket_requests (keyed by purpose)"
  value = {
    for key, bucket in aws_s3_bucket.requested :
    key => {
      bucket_name = bucket.bucket
      bucket_arn  = bucket.arn
      purpose     = local.buckets[key].purpose
      description = local.buckets[key].description
    }
  }
}

# Bucket names map (for easy lookup)
output "bucket_names" {
  description = "Map of purpose => bucket name"
  value = {
    for key, bucket in aws_s3_bucket.requested :
    key => bucket.bucket
  }
}

# Replacement trigger IDs (keyed by purpose) - UUID changes whenever the bucket
# is recreated, allowing downstream modules to detect bucket replacement via triggers.
output "bucket_replacement_triggers" {
  description = "Map of purpose => trigger ID that changes when the bucket is recreated"
  value = {
    for k, r in terraform_data.bucket_replaced : k => r.id
  }
}

# Bucket ARNs map (for IAM policies)
output "bucket_arns" {
  description = "Map of purpose => bucket ARN"
  value = {
    for key, bucket in aws_s3_bucket.requested :
    key => bucket.arn
  }
}

# Access logs bucket (if created)
output "access_logs_bucket" {
  description = "Centralized access logs bucket (if any bucket requested access_logging)"
  value = local.needs_log_bucket ? {
    bucket_name = aws_s3_bucket.access_logs[0].bucket
    bucket_arn  = aws_s3_bucket.access_logs[0].arn
  } : null
}

# Configuration summary
output "config" {
  description = "Storage service configuration summary"
  value = {
    total_buckets         = length(aws_s3_bucket.requested)
    bucket_purposes       = keys(local.buckets)
    total_rds_clusters    = length(module.rds_aurora)
    rds_purposes          = keys(local.rds_clusters)
    total_rds_instances   = length(aws_db_instance.requested)
    rds_instance_purposes = keys(local.rds_instances)
    total_cache_clusters  = length(aws_elasticache_replication_group.valkey_redis) + length(aws_elasticache_cluster.memcached)
    cache_purposes        = keys(local.elasticache_clusters)
    total_repositories    = length(aws_codecommit_repository.requested)
    repository_purposes   = keys(local.repositories)
    total_volumes         = length(aws_ebs_volume.requested)
    volume_purposes       = keys(local.volumes)
    access_logging        = local.needs_log_bucket
    region                = data.aws_region.current.id
  }
}

# RDS clusters (keyed by purpose)
output "rds_clusters" {
  description = "RDS Aurora clusters created from rds_cluster_requests (keyed by purpose)"
  value = {
    for k, cluster in module.rds_aurora : k => {
      endpoint        = cluster.cluster_endpoint
      reader_endpoint = cluster.cluster_reader_endpoint
      database_name   = local.rds_clusters[k].database_name
      master_username = local.rds_clusters[k].database_name # username = database name
      password        = random_password.rds[k].result
      port            = 5432
      cluster_id      = cluster.cluster_id
    }
  }
  sensitive = true
}

# RDS standalone instances (keyed by purpose)
output "rds_instances" {
  description = "RDS standalone instances created from rds_instance_requests (keyed by purpose)"
  value = {
    for k, inst in aws_db_instance.requested : k => {
      endpoint        = inst.endpoint
      address         = inst.address
      port            = inst.port
      engine          = inst.engine
      master_username = inst.username
      password        = random_password.rds_instance[k].result
      identifier      = inst.identifier
    }
  }
  sensitive = true
}

# RDS instance security group IDs (for creating ingress rules from other modules)
output "rds_instance_security_group_ids" {
  description = "RDS instance security group IDs (map: purpose => sg_id)"
  value = {
    for k, sg in aws_security_group.rds_instance :
    k => sg.id
  }
}

# ElastiCache clusters (keyed by purpose)
output "elasticache_clusters" {
  description = "ElastiCache clusters created from elasticache_cluster_requests (keyed by purpose)"
  value = merge(
    # Valkey/Redis replication groups
    {
      for k, rg in aws_elasticache_replication_group.valkey_redis : k => {
        endpoint               = rg.primary_endpoint_address
        port                   = rg.port
        configuration_endpoint = null # Not applicable for Redis/Valkey
        engine                 = rg.engine
      }
    },
    # Memcached clusters
    {
      for k, cluster in aws_elasticache_cluster.memcached : k => {
        endpoint               = cluster.cache_nodes[0].address
        port                   = cluster.port
        configuration_endpoint = cluster.configuration_endpoint
        engine                 = cluster.engine
      }
    }
  )
}

# Security group IDs (for creating ingress rules from other modules)
output "rds_security_group_id" {
  description = "RDS security group ID (for adding ingress rules)"
  value       = length(aws_security_group.rds) > 0 ? aws_security_group.rds[0].id : ""
}

output "elasticache_security_group_id" {
  description = "ElastiCache security group ID (for adding ingress rules)"
  value       = length(aws_security_group.elasticache) > 0 ? aws_security_group.elasticache[0].id : ""
}

# CodeCommit repositories (keyed by purpose)
output "repositories" {
  description = "CodeCommit repositories created from repository_requests (keyed by purpose)"
  value = {
    for key, repo in aws_codecommit_repository.requested :
    key => {
      repo_name   = repo.repository_name
      clone_url   = repo.clone_url_http
      arn         = repo.arn
      purpose     = local.repositories[key].purpose
      description = local.repositories[key].description
    }
  }
}

# Self-service action commands for portal (dependency inversion)
output "commands" {
  description = "Portal self-service action commands from the storage module"
  value = [
    for k, bucket in aws_s3_bucket.requested : {
      title          = "Taint S3 Bucket"
      description    = "Force Terraform to destroy and recreate this S3 bucket on next apply"
      commands       = ["terraform apply -replace='module.storage[0].aws_s3_bucket.requested[\"${k}\"]'"]
      service        = "storage"
      category       = "s3-taint-${k}"
      target_type    = "storage"
      target         = k
      execution      = "local"
      blueprint_type = "storage"
      action_config = {
        type                      = "state_taint"
        resource_address_template = "module.storage[0].aws_s3_bucket.requested[\"${k}\"]"
        workspace                 = terraform.workspace
        region                    = data.aws_region.current.id
      }
    }
  ]
}

# Non-sensitive storage inventory for the portal catalog.
# Contains one entry per created resource with display metadata only -
# no endpoints, passwords, or connection strings.
output "inventory" {
  description = "Non-sensitive storage resource summary for portal catalog (keyed by purpose)"
  value = concat(
    # S3 buckets
    [for k, bucket in aws_s3_bucket.requested : {
      purpose          = k
      storage_type     = "s3"
      name             = bucket.bucket
      engine           = null
      description      = local.buckets[k].description
      url              = "https://s3.console.aws.amazon.com/s3/buckets/${bucket.bucket}?region=${data.aws_region.current.id}"
      resource_address = "module.storage[0].aws_s3_bucket.requested[\"${k}\"]"
    }],
    # RDS Aurora clusters
    [for k, cluster in module.rds_aurora : {
      purpose      = k
      storage_type = "rds-aurora"
      name         = cluster.cluster_id
      engine       = local.rds_clusters[k].engine
      description  = ""
      url          = "https://${data.aws_region.current.id}.console.aws.amazon.com/rds/home?region=${data.aws_region.current.id}#database:id=${cluster.cluster_id}"
    }],
    # RDS standalone instances
    [for k, inst in aws_db_instance.requested : {
      purpose      = k
      storage_type = "rds-standalone"
      name         = inst.identifier
      engine       = local.rds_instances[k].engine
      description  = ""
      url          = "https://${data.aws_region.current.id}.console.aws.amazon.com/rds/home?region=${data.aws_region.current.id}#dbinstances:search=${inst.identifier}"
    }],
    # ElastiCache Valkey / Redis replication groups
    [for k, rg in aws_elasticache_replication_group.valkey_redis : {
      purpose      = k
      storage_type = "elasticache-${local.elasticache_clusters[k].engine}"
      name         = rg.id
      engine       = local.elasticache_clusters[k].engine
      description  = ""
      url          = "https://${data.aws_region.current.id}.console.aws.amazon.com/elasticache/home?region=${data.aws_region.current.id}#/redis/${rg.id}"
    }],
    # ElastiCache Memcached clusters
    [for k, cluster in aws_elasticache_cluster.memcached : {
      purpose      = k
      storage_type = "elasticache-memcached"
      name         = cluster.id
      engine       = "memcached"
      description  = ""
      url          = "https://${data.aws_region.current.id}.console.aws.amazon.com/elasticache/home?region=${data.aws_region.current.id}#/memcached/${cluster.id}"
    }],
    # CodeCommit repositories
    [for k, repo in aws_codecommit_repository.requested : {
      purpose      = k
      storage_type = "codecommit"
      name         = repo.repository_name
      engine       = null
      description  = local.repositories[k].description
      url          = "https://${data.aws_region.current.id}.console.aws.amazon.com/codesuite/codecommit/repositories/${repo.repository_name}/browse?region=${data.aws_region.current.id}"
    }],
    # EBS volumes
    [for k, v in aws_ebs_volume.requested : {
      purpose      = k
      storage_type = "ebs"
      name         = v.tags["Name"]
      engine       = null
      description  = local.volumes[k].description
      url          = "https://${data.aws_region.current.id}.console.aws.amazon.com/ec2/home?region=${data.aws_region.current.id}#VolumeDetails:volumeId=${v.id}"
    }],
  )
}

# Access: Security Groups (dependency inversion interface for access module)
output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = local.access_security_groups
}

# Access: Resource Policies (dependency inversion interface for access module)
output "access_resource_policies" {
  description = "S3 bucket policies for the access module (AWS-native format)"
  value       = local.access_resource_policies
}

# EBS volumes (keyed by purpose)
output "volumes" {
  description = "EBS volumes created from volume_requests (keyed by purpose)"
  value = {
    for k, v in aws_ebs_volume.requested : k => {
      id                = v.id
      availability_zone = v.availability_zone
      size              = v.size
      type              = v.type
      device_name       = aws_volume_attachment.requested[k].device_name
      instance_id       = aws_volume_attachment.requested[k].instance_id
    }
  }
}

# Repository names map (for easy lookup)
output "repository_names" {
  description = "Map of purpose => repository name"
  value = {
    for key, repo in aws_codecommit_repository.requested :
    key => repo.repository_name
  }
}

# Clone URLs map (for git operations)
output "clone_urls" {
  description = "Map of purpose => HTTPS clone URL"
  value = {
    for key, repo in aws_codecommit_repository.requested :
    key => repo.clone_url_http
  }
}
