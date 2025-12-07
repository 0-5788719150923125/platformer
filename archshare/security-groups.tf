# Security group rules for compute → storage access
# Created here to break circular dependency
# Storage creates security groups with no ingress rules initially
# After compute module exists, we add rules to allow access

# Allow Archshare EC2 instances to access RDS PostgreSQL (port 5432)
resource "aws_security_group_rule" "compute_to_rds" {
  for_each = var.storage_enabled ? toset(
    [for key, dt in local.deployment_tenant_map : "${dt.deployment}-${dt.tenant}"
    if try(var.compute_security_groups["${dt.deployment}-${dt.tenant}"], "") != ""]
  ) : toset([])

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.storage_rds_security_group_id
  source_security_group_id = var.compute_security_groups[each.key]
  description              = "Allow ${each.key} compute instances to access RDS"
}

# Allow Archshare EC2 instances to access ElastiCache Redis/Valkey (port 6379)
resource "aws_security_group_rule" "compute_to_redis" {
  for_each = var.storage_enabled ? toset(
    [for key, dt in local.deployment_tenant_map : "${dt.deployment}-${dt.tenant}"
    if try(var.compute_security_groups["${dt.deployment}-${dt.tenant}"], "") != ""]
  ) : toset([])

  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = var.storage_elasticache_security_group_id
  source_security_group_id = var.compute_security_groups[each.key]
  description              = "Allow ${each.key} compute instances to access Redis/Valkey"
}

# Allow Archshare EC2 instances to access ElastiCache Memcached (port 11211)
resource "aws_security_group_rule" "compute_to_memcached" {
  for_each = var.storage_enabled ? toset(
    [for key, dt in local.deployment_tenant_map : "${dt.deployment}-${dt.tenant}"
    if try(var.compute_security_groups["${dt.deployment}-${dt.tenant}"], "") != ""]
  ) : toset([])

  type                     = "ingress"
  from_port                = 11211
  to_port                  = 11211
  protocol                 = "tcp"
  security_group_id        = var.storage_elasticache_security_group_id
  source_security_group_id = var.compute_security_groups[each.key]
  description              = "Allow ${each.key} compute instances to access Memcached"
}

# ============================================================================
# EKS Cluster Security Group Rules
# ============================================================================

# Allow EKS cluster pods to access RDS PostgreSQL (port 5432)
resource "aws_security_group_rule" "eks_to_rds" {
  for_each = var.storage_enabled ? var.eks_cluster_security_groups : {}

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.storage_rds_security_group_id
  source_security_group_id = each.value
  description              = "Allow EKS cluster ${each.key} pods to access RDS"
}

# Allow EKS cluster pods to access ElastiCache Redis/Valkey (port 6379)
resource "aws_security_group_rule" "eks_to_redis" {
  for_each = var.storage_enabled ? var.eks_cluster_security_groups : {}

  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = var.storage_elasticache_security_group_id
  source_security_group_id = each.value
  description              = "Allow EKS cluster ${each.key} pods to access Redis/Valkey"
}

# Allow EKS cluster pods to access ElastiCache Memcached (port 11211)
resource "aws_security_group_rule" "eks_to_memcached" {
  for_each = var.storage_enabled ? var.eks_cluster_security_groups : {}

  type                     = "ingress"
  from_port                = 11211
  to_port                  = 11211
  protocol                 = "tcp"
  security_group_id        = var.storage_elasticache_security_group_id
  source_security_group_id = each.value
  description              = "Allow EKS cluster ${each.key} pods to access Memcached"
}
