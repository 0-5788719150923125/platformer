# ElastiCache clusters (Valkey/Memcached) - dependency inversion pattern
# Modules define cluster requirements via elasticache_cluster_requests variable

locals {
  # Create map of clusters from requests (keyed by purpose for easy lookup)
  elasticache_clusters = {
    for idx, req in var.elasticache_cluster_requests :
    req.purpose => {
      engine                     = req.engine
      engine_version             = req.engine_version
      node_type                  = req.node_type
      num_cache_nodes            = req.num_cache_nodes
      transit_encryption_enabled = req.transit_encryption_enabled
      subnet_ids                 = req.subnet_ids
      vpc_id                     = req.vpc_id
      allowed_sg_ids             = req.allowed_security_group_ids
    }
  }

  # Split into Valkey/Redis (replication groups) and Memcached (clusters)
  valkey_redis_clusters = {
    for key, cluster in local.elasticache_clusters :
    key => cluster
    if cluster.engine == "valkey" || cluster.engine == "redis"
  }

  memcached_clusters = {
    for key, cluster in local.elasticache_clusters :
    key => cluster
    if cluster.engine == "memcached"
  }

  # Generate shortened IDs for AWS ElastiCache (limit: 40 chars)
  # Format: ${namespace}-${key} or ${namespace}-${prefix}-${hash} if too long
  # Keeps descriptive suffix + deterministic hash of full key for uniqueness
  # Example: "archshare-training-services-cache" → "chimos-services-cache-38303"
  replication_group_ids = {
    for key in keys(local.valkey_redis_clusters) :
    key => (
      length("${var.namespace}-${key}") <= 40
      ? "${var.namespace}-${key}"
      : (
        # Extract suffix (last segment after last hyphen, e.g., "cache" or "services-cache")
        # Keep last 2 segments if possible for descriptiveness
        length(split("-", key)) >= 2
        ? "${var.namespace}-${join("-", slice(split("-", key), length(split("-", key)) - 2, length(split("-", key))))}-${substr(md5(key), 0, 5)}"
        : "${var.namespace}-${substr(md5(key), 0, 40 - length(var.namespace) - 1)}"
      )
    )
  }

  memcached_cluster_ids = {
    for key in keys(local.memcached_clusters) :
    key => (
      length("${var.namespace}-${key}") <= 40
      ? "${var.namespace}-${key}"
      : (
        length(split("-", key)) >= 2
        ? "${var.namespace}-${join("-", slice(split("-", key), length(split("-", key)) - 2, length(split("-", key))))}-${substr(md5(key), 0, 5)}"
        : "${var.namespace}-${substr(md5(key), 0, 40 - length(var.namespace) - 1)}"
      )
    )
  }
}

# Cache subnet group (shared across all ElastiCache clusters)
resource "aws_elasticache_subnet_group" "main" {
  count = length(local.elasticache_clusters) > 0 ? 1 : 0

  name       = "${var.namespace}-cache-subnet-group"
  subnet_ids = tolist(toset(flatten([for cluster in local.elasticache_clusters : cluster.subnet_ids])))

  tags = {
    Name      = "${var.namespace}-cache-subnet-group"
    Namespace = var.namespace
  }
}

# Security group for ElastiCache
resource "aws_security_group" "elasticache" {
  count = length(local.elasticache_clusters) > 0 ? 1 : 0

  name_prefix = "${var.namespace}-cache-"
  description = "ElastiCache security group"
  vpc_id      = local.elasticache_clusters[keys(local.elasticache_clusters)[0]].vpc_id

  tags = {
    Name      = "${var.namespace}-cache"
    Namespace = var.namespace
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Allow Redis (6379) or Memcached (11211) from allowed security groups
resource "aws_security_group_rule" "elasticache_ingress" {
  for_each = {
    for pair in flatten([
      for cluster_key, cluster in local.elasticache_clusters : [
        for sg_id in cluster.allowed_sg_ids : {
          cluster_key = cluster_key
          sg_id       = sg_id
          port        = cluster.engine == "memcached" ? 11211 : 6379
        }
      ]
    ]) : "${pair.cluster_key}-${pair.sg_id}" => pair
  }

  type                     = "ingress"
  from_port                = each.value.port
  to_port                  = each.value.port
  protocol                 = "tcp"
  source_security_group_id = each.value.sg_id
  security_group_id        = aws_security_group.elasticache[0].id
  description              = "Cache access from ${each.value.cluster_key}"
}

# Valkey/Redis clusters (use replication group for Valkey support)
resource "aws_elasticache_replication_group" "valkey_redis" {
  for_each = local.valkey_redis_clusters

  replication_group_id = local.replication_group_ids[each.key]
  description          = "ElastiCache ${each.value.engine} cluster for ${each.key}"

  engine               = each.value.engine
  engine_version       = each.value.engine_version
  node_type            = each.value.node_type
  num_cache_clusters   = each.value.num_cache_nodes
  parameter_group_name = each.value.engine == "valkey" ? "default.valkey8" : "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main[0].name
  security_group_ids = [aws_security_group.elasticache[0].id]

  transit_encryption_enabled = each.value.transit_encryption_enabled
  at_rest_encryption_enabled = true
  automatic_failover_enabled = false # Single-node for dev

  tags = {
    Name      = "${var.namespace}-${each.key}"
    Purpose   = each.key
    Namespace = var.namespace
  }
}

# Memcached clusters (use cluster resource)
resource "aws_elasticache_cluster" "memcached" {
  for_each = local.memcached_clusters

  cluster_id           = local.memcached_cluster_ids[each.key]
  engine               = "memcached"
  engine_version       = each.value.engine_version
  node_type            = each.value.node_type
  num_cache_nodes      = each.value.num_cache_nodes
  parameter_group_name = "default.memcached1.6"
  port                 = 11211
  subnet_group_name    = aws_elasticache_subnet_group.main[0].name
  security_group_ids   = [aws_security_group.elasticache[0].id]

  tags = {
    Name      = "${var.namespace}-${each.key}"
    Purpose   = each.key
    Namespace = var.namespace
  }
}
