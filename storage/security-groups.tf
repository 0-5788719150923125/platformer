locals {
  access_security_groups = concat(
    # RDS Aurora security group
    length(aws_security_group.rds) > 0 ? [
      {
        module      = "storage"
        group_name  = aws_security_group.rds[0].name
        description = aws_security_group.rds[0].description
        ingress = flatten([
          for cluster_key, cluster in local.rds_clusters : [
            for sg_id in cluster.allowed_sg_ids : {
              description           = "PostgreSQL from ${cluster_key}"
              protocol              = "tcp"
              from_port             = 5432
              to_port               = 5432
              cidr_blocks           = []
              source_security_group = sg_id
              self                  = false
            }
          ]
        ])
        egress = []
      }
    ] : [],
    # RDS standalone instance security groups (one per instance)
    [
      for k, sg in aws_security_group.rds_instance : {
        module      = "storage"
        group_name  = sg.name
        description = sg.description
        ingress = [
          for idx, sg_id in local.rds_instances[k].allowed_sg_ids : {
            description           = "Database access from ${k}"
            protocol              = "tcp"
            from_port             = local.rds_instance_is_sqlserver[k] ? 1433 : 5432
            to_port               = local.rds_instance_is_sqlserver[k] ? 1433 : 5432
            cidr_blocks           = []
            source_security_group = sg_id
            self                  = false
          }
        ]
        egress = []
      }
    ],
    # ElastiCache security group
    length(aws_security_group.elasticache) > 0 ? [
      {
        module      = "storage"
        group_name  = aws_security_group.elasticache[0].name
        description = aws_security_group.elasticache[0].description
        ingress = flatten([
          for cluster_key, cluster in local.elasticache_clusters : [
            for sg_id in cluster.allowed_sg_ids : {
              description           = "Cache access from ${cluster_key} (${cluster.engine})"
              protocol              = "tcp"
              from_port             = cluster.engine == "memcached" ? 11211 : 6379
              to_port               = cluster.engine == "memcached" ? 11211 : 6379
              cidr_blocks           = []
              source_security_group = sg_id
              self                  = false
            }
          ]
        ])
        egress = []
      }
    ] : [],
  )
}
