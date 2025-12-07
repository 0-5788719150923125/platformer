# RDS Aurora PostgreSQL clusters (dependency inversion pattern)
# Modules define cluster requirements via rds_cluster_requests variable

locals {
  # Split requests by type
  aurora_requests     = [for req in var.rds_cluster_requests : req if req.type == "aurora"]
  standalone_requests = [for req in var.rds_cluster_requests : req if req.type == "standalone"]

  # Create map of Aurora clusters from requests (keyed by purpose for easy lookup)
  rds_clusters = {
    for idx, req in local.aurora_requests :
    req.purpose => {
      name                    = req.name
      database_name           = req.database_name
      engine                  = req.engine
      engine_version          = req.engine_version
      instance_class          = req.instance_class
      instances               = req.instances
      deletion_protection     = req.deletion_protection
      backup_retention_period = req.backup_retention_period
      final_snapshot          = req.final_snapshot
      subnet_ids              = req.subnet_ids
      vpc_id                  = req.vpc_id
      allowed_sg_ids          = req.allowed_security_group_ids
    }
  }
}

# DB subnet group (one per storage module instantiation, shared across all RDS clusters)
resource "aws_db_subnet_group" "main" {
  count = length(local.rds_clusters) > 0 ? 1 : 0

  name       = "${var.namespace}-db-subnet-group"
  subnet_ids = tolist(toset(flatten([for cluster in local.rds_clusters : cluster.subnet_ids])))

  tags = {
    Name      = "${var.namespace}-db-subnet-group"
    Namespace = var.namespace
  }
}

# Security group for RDS (private-postgres access)
resource "aws_security_group" "rds" {
  count = length(local.rds_clusters) > 0 ? 1 : 0

  name_prefix = "${var.namespace}-rds-"
  description = "RDS Aurora PostgreSQL security group"
  vpc_id      = local.rds_clusters[keys(local.rds_clusters)[0]].vpc_id

  tags = {
    Name      = "${var.namespace}-rds"
    Namespace = var.namespace
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Allow PostgreSQL (5432) from allowed security groups
resource "aws_security_group_rule" "rds_ingress" {
  for_each = {
    for pair in flatten([
      for cluster_key, cluster in local.rds_clusters : [
        for sg_id in cluster.allowed_sg_ids : {
          cluster_key = cluster_key
          sg_id       = sg_id
        }
      ]
    ]) : "${pair.cluster_key}-${pair.sg_id}" => pair
  }

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = each.value.sg_id
  security_group_id        = aws_security_group.rds[0].id
  description              = "PostgreSQL from ${each.value.cluster_key}"
}

# Random passwords for RDS clusters
resource "random_password" "rds" {
  for_each = local.rds_clusters

  length  = 24
  special = false
}

# RDS Aurora clusters using community module
module "rds_aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "9.13.0"

  for_each = local.rds_clusters

  name                        = each.value.name
  database_name               = each.value.database_name
  engine                      = "aurora-postgresql"
  engine_version              = each.value.engine_version
  instance_class              = each.value.instance_class
  instances                   = tomap({ for i in range(1, each.value.instances + 1) : i => {} })
  master_username             = each.value.database_name # Username = database name
  master_password             = random_password.rds[each.key].result
  manage_master_user_password = false

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_id                 = each.value.vpc_id
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  create_security_group  = false
  create_db_subnet_group = false

  deletion_protection       = each.value.deletion_protection
  backup_retention_period   = each.value.backup_retention_period
  skip_final_snapshot       = !each.value.final_snapshot
  final_snapshot_identifier = each.value.final_snapshot ? "${each.value.name}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  auto_minor_version_upgrade  = false
  allow_major_version_upgrade = true

  tags = {
    Name      = each.value.name
    Purpose   = each.key
    Namespace = var.namespace
  }
}

# ── Standalone RDS Instances (non-Aurora, e.g., SQL Server) ─────────────────
# Modules define instance requirements via rds_cluster_requests variable (type = "standalone")

locals {
  rds_instances = {
    for idx, req in local.standalone_requests :
    req.purpose => {
      name                    = req.name
      engine                  = req.engine
      engine_version          = req.engine_version
      instance_class          = req.instance_class
      allocated_storage       = req.allocated_storage
      storage_type            = req.storage_type
      iops                    = req.iops
      multi_az                = req.multi_az
      deletion_protection     = req.deletion_protection
      backup_retention_period = req.backup_retention_period
      subnet_ids              = req.subnet_ids
      vpc_id                  = req.vpc_id
      allowed_sg_ids          = req.allowed_security_group_ids
    }
  }

  # Detect if engine is SQL Server (license_model required)
  rds_instance_is_sqlserver = {
    for k, v in local.rds_instances :
    k => startswith(v.engine, "sqlserver")
  }
}

# DB subnet group for standalone instances (shared)
resource "aws_db_subnet_group" "instance" {
  count = length(local.rds_instances) > 0 ? 1 : 0

  name       = "${var.namespace}-db-instance-subnet-group"
  subnet_ids = tolist(toset(flatten([for inst in local.rds_instances : inst.subnet_ids])))

  tags = {
    Name      = "${var.namespace}-db-instance-subnet-group"
    Namespace = var.namespace
  }
}

# Security groups for standalone RDS instances (one per instance for isolation)
resource "aws_security_group" "rds_instance" {
  for_each = local.rds_instances

  name_prefix = "${var.namespace}-rds-${each.key}-"
  description = "RDS instance security group (${each.key})"
  vpc_id      = each.value.vpc_id

  tags = {
    Name      = "${var.namespace}-rds-${each.key}"
    Purpose   = each.key
    Namespace = var.namespace
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Allow database port from allowed security groups
# Use index-based keys to avoid unknown SG IDs in for_each keys at plan time
resource "aws_security_group_rule" "rds_instance_ingress" {
  for_each = {
    for pair in flatten([
      for inst_key, inst in local.rds_instances : [
        for idx, sg_id in inst.allowed_sg_ids : {
          inst_key = inst_key
          sg_idx   = idx
          sg_id    = sg_id
        }
      ]
    ]) : "${pair.inst_key}-${pair.sg_idx}" => pair
  }

  type                     = "ingress"
  from_port                = local.rds_instance_is_sqlserver[each.value.inst_key] ? 1433 : 5432
  to_port                  = local.rds_instance_is_sqlserver[each.value.inst_key] ? 1433 : 5432
  protocol                 = "tcp"
  source_security_group_id = each.value.sg_id
  security_group_id        = aws_security_group.rds_instance[each.value.inst_key].id
  description              = "Database access from ${each.value.inst_key}"
}

# Random passwords for standalone RDS instances
resource "random_password" "rds_instance" {
  for_each = local.rds_instances

  length  = 24
  special = false
}

# Standalone RDS instances
resource "aws_db_instance" "requested" {
  for_each = local.rds_instances

  identifier = each.value.name

  engine         = each.value.engine
  engine_version = each.value.engine_version
  instance_class = each.value.instance_class

  allocated_storage = each.value.allocated_storage
  storage_type      = each.value.storage_type
  iops              = each.value.iops

  username = "admin"
  password = random_password.rds_instance[each.key].result

  db_subnet_group_name   = aws_db_subnet_group.instance[0].name
  vpc_security_group_ids = [aws_security_group.rds_instance[each.key].id]

  multi_az            = each.value.multi_az
  deletion_protection = each.value.deletion_protection

  backup_retention_period = each.value.backup_retention_period
  skip_final_snapshot     = true

  # SQL Server requires license model
  license_model = local.rds_instance_is_sqlserver[each.key] ? "license-included" : null

  auto_minor_version_upgrade = false

  tags = {
    Name      = each.value.name
    Purpose   = each.key
    Namespace = var.namespace
  }
}
