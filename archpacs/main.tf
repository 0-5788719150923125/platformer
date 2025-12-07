# ArchPACS Module
# Domain orchestration for ArchPACS medical imaging PACS deployments
# Generates infrastructure requests (RDS, S3) via dependency inversion
# Supports multi-deployment, multi-tenant configurations
# Uses Maestro for PACS application installation on native Rocky Linux 8

# RDS Cluster Requests (LifeImage CNS database per deployment x tenant)
locals {
  rds_cluster_requests = flatten([
    for deploy_name, config in var.config : [
      for tenant_code in lookup(var.tenants_by_deployment, deploy_name, []) : {
        type          = "aurora"
        name          = "${var.namespace}-${deploy_name}-${tenant_code}-lifimage-cns"
        purpose       = "${deploy_name}-${tenant_code}-lifimage-cns"
        database_name = config.rds.lifimage_cns.database_name

        engine_version          = config.rds.lifimage_cns.engine_version
        instance_class          = config.rds.lifimage_cns.instance_class
        instances               = config.rds.lifimage_cns.instances
        deletion_protection     = config.rds.lifimage_cns.deletion_protection
        backup_retention_period = config.rds.lifimage_cns.backup_retention_period
        final_snapshot          = false # Dev: no final snapshot

        subnet_ids = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
        vpc_id     = local.network_by_deployment[deploy_name].network_summary.vpc_id
      }
    ] if config.rds != null
  ])
}

# S3 Bucket Requests (file transfer, backups, logs per deployment x tenant)
locals {
  bucket_requests = flatten([
    for deploy_name, config in var.config : [
      for tenant_code in lookup(var.tenants_by_deployment, deploy_name, []) : [
        for bucket_config in config.s3 : {
          purpose     = "${deploy_name}-${tenant_code}-${bucket_config.purpose}"
          description = "ArchPACS ${bucket_config.purpose} for ${deploy_name}/${tenant_code}"
          prefix      = "${tenant_code}-${var.namespace}"

          versioning_enabled = bucket_config.versioning
          force_destroy      = false # Production safety

          # Lifecycle policies (optional)
          lifecycle_rules = bucket_config.lifecycle != null ? [
            {
              enabled = true
              transitions = [
                for storage_class, days in bucket_config.lifecycle : {
                  days          = days
                  storage_class = storage_class
                }
              ]
              expiration_days = bucket_config.retention_days
            }
          ] : []
        }
      ]
    ] if config.s3 != null
  ])
}

# ── Maestro Deploy Secrets ────────────────────────────────────────────────────
# Generate a random password per deployment for PACS admin + database SA.
# Stored in SSM Parameter Store; retrieved at runtime by the bootstrap playbook.

resource "random_password" "maestro_deploy" {
  for_each = local.maestro_deployments

  length  = 16
  special = false # Maestro docs: ( , + % . & * ) ! % - @ < = > : / ? ; are not allowed in SA password
}

resource "aws_ssm_parameter" "maestro_deploy_password" {
  for_each = local.maestro_deployments

  name  = "/${var.namespace}/archpacs/${each.key}/maestro-deploy-password"
  type  = "SecureString"
  value = random_password.maestro_deploy[each.key].result

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archpacs"
  }
}

# ── Maestro SSH Keypair ──────────────────────────────────────────────────────
# Shared SSH keypair for bidirectional trust between all PACS nodes.
# Generated at apply time so all nodes can retrieve it from SSM on first run.
# Maestro requires passwordless SSH in both directions (orchestrator ↔ runners).

resource "tls_private_key" "maestro_ssh" {
  for_each = local.maestro_deployments

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_ssm_parameter" "maestro_ssh_privkey" {
  for_each = local.maestro_deployments

  name  = "/${var.namespace}/archpacs/${each.key}/ssh-privkey"
  type  = "SecureString"
  value = tls_private_key.maestro_ssh[each.key].private_key_openssh

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archpacs"
  }
}

resource "aws_ssm_parameter" "maestro_ssh_pubkey" {
  for_each = local.maestro_deployments

  name  = "/${var.namespace}/archpacs/${each.key}/ssh-pubkey"
  type  = "String"
  value = trimspace(tls_private_key.maestro_ssh[each.key].public_key_openssh)

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archpacs"
  }
}
