# AWS
#
# Linked into the root as provider_aws.tf by scripts/providers.sh, only in
# workspaces whose tfvars set aws_profile (nearly all of them). Everywhere else
# AWS is never downloaded or set up. With it come the account and region
# lookups, the AWS adapters of every service (each service's aws/wiring.tf.tmpl),
# and the products built on AWS alone.

provider "aws" {
  region  = module.workspaces.aws_region
  profile = module.workspaces.aws_profile


  default_tags {
    tags = local.aws_configured ? {
      ManagedBy = "Terraform"
      Project   = "Platformer"
      Owner     = module.workspaces.owner
    } : {}
  }
}

provider "aws" {
  alias                       = "prod"
  profile                     = try(var.cross_account_providers["prod"].profile, null)
  region                      = try(var.cross_account_providers["prod"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "prod")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "prod")
}

provider "aws" {
  alias                       = "infrastructure"
  profile                     = try(var.cross_account_providers["infrastructure"].profile, null)
  region                      = try(var.cross_account_providers["infrastructure"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "infrastructure")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "infrastructure")
}

locals {
  prod_provider_configured = contains(keys(var.cross_account_providers), "prod")
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# One-cloud products

# arcbot Module
# Event-driven AI automation pipeline - Jira webhook -> SQS -> Lambda -> Devin -> Jira comment
# No dependencies on compute, storage, or networking modules
module "arcbot" {
  count  = local.arcbot_enabled ? 1 : 0
  source = "./arcbot"

  namespace   = module.namespace.id
  config      = module.config.service_configs["arcbot"]
  aws_profile = module.workspaces.aws_profile

  # Secrets replicated by the secrets module (dependency inversion)
  atlassian_secret_arn = local.secrets_enabled ? module.secrets[0].replicated_secret_arns["arcbot/atlassian_pat"] : ""
  devin_secret_arn     = local.secrets_enabled ? module.secrets[0].replicated_secret_arns["arcbot/devin_api_key"] : ""

  # Event bus webhooks from portal module (dependency inversion)
  event_bus_webhooks = local.portal_event_bus_webhooks

  # KB documents bucket from storage module (dependency inversion)
  kb_documents_bucket_name    = local.storage_enabled && contains(keys(module.storage[0].bucket_names), "arcbot-kb-docs") ? module.storage[0].bucket_names["arcbot-kb-docs"] : ""
  kb_documents_bucket_arn     = local.storage_enabled && contains(keys(module.storage[0].bucket_arns), "arcbot-kb-docs") ? module.storage[0].bucket_arns["arcbot-kb-docs"] : ""
  kb_documents_bucket_trigger = local.storage_enabled && contains(keys(module.storage[0].bucket_replacement_triggers), "arcbot-kb-docs") ? module.storage[0].bucket_replacement_triggers["arcbot-kb-docs"] : ""

  # Access return-path (IAM resources created by access module)
  access_iam_role_arns  = module.access.iam_role_arns
  access_iam_role_names = module.access.iam_role_names
}

# IOPACS Module
# Medical imaging PACS platform - generates infrastructure requests for compute, storage, and applications
module "iopacs" {
  count  = local.iopacs_enabled ? 1 : 0
  source = "./iopacs"

  # Core variables
  namespace = module.namespace.id

  # Service-specific configuration
  # Each key is a named deployment containing compute + RDS + S3 config
  config = module.config.service_configs["iopacs"]

  # Per-deployment tenant lists (from entitlements system)
  # Deployment name = class name, so tenants_by_class maps deployment → tenants
  tenants_by_deployment = {
    for name in try(keys(module.config.service_configs["iopacs"]), []) :
    name => try(module.tenants.tenants_by_class[name], [])
  }

  # Network module outputs (dependency inversion)
  networks = module.networks
}

# IOrchestrator Module
# IO Cloud / SaaSApp platform - ECS Fargate services with MSSQL backend
# Generates infrastructure requests for storage module (RDS SQL Server, S3)
module "iorchestrator" {
  count  = local.iorchestrator_enabled ? 1 : 0
  source = "./iorchestrator"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region
  aws_profile    = module.workspaces.aws_profile

  # Service-specific configuration
  # Each key is a named deployment (IO Cloud "instance") containing ECS + RDS + S3 config
  config = module.config.service_configs["iorchestrator"]

  # Per-deployment tenant lists (from entitlements system)
  # Deployment name = class name, so tenants_by_class maps deployment → tenants
  tenants_by_deployment = {
    for name in try(keys(module.config.service_configs["iorchestrator"]), []) :
    name => try(module.tenants.tenants_by_class[name], [])
  }

  # Network module outputs (dependency inversion)
  networks = module.networks

  # Pass compute outputs back (dependency inversion return path)
  # Compute module creates ECS clusters based on requests
  ecs_clusters = local.compute_enabled ? module.compute[0].ecs_clusters : {}

  # Pass storage outputs back (dependency inversion return path)
  # Storage module creates RDS instances and S3 buckets, then we pass endpoints back
  rds_instances = local.storage_enabled ? module.storage[0].rds_instances : {}
  s3_buckets    = local.storage_enabled ? module.storage[0].bucket_names : {}

  # Access return-path (IAM resources created by access module)
  access_iam_role_arns  = module.access.iam_role_arns
  access_iam_role_names = module.access.iam_role_names
}

# Ioshare Module
# Medical imaging platform orchestration - generates infrastructure requests for storage module
module "ioshare" {
  count  = local.ioshare_enabled ? 1 : 0
  source = "./ioshare"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id

  # Service-specific configuration (defaults handled by module)
  # Each key is a named deployment containing compute + RDS + ElastiCache config
  config = module.config.service_configs["ioshare"]

  # Per-deployment tenant lists (from entitlements system)
  # Deployment name = class name, so tenants_by_class maps deployment → tenants
  tenants_by_deployment = {
    for name in try(keys(module.config.service_configs["ioshare"]), []) :
    name => try(module.tenants.tenants_by_class[name], [])
  }

  # Network module outputs (dependency inversion)
  networks = module.networks

  # Pass storage outputs back (dependency inversion return path)
  # Storage module creates resources, then we pass endpoints back to ioshare
  rds_clusters         = local.storage_enabled ? module.storage[0].rds_clusters : {}
  elasticache_clusters = local.storage_enabled ? module.storage[0].elasticache_clusters : {}
  s3_buckets           = local.storage_enabled ? module.storage[0].bucket_names : {}
  efs_filesystems      = {} # Not implemented yet

  # Pass storage security group IDs (for ioshare to create access rules)
  storage_enabled                       = local.storage_enabled
  storage_rds_security_group_id         = local.storage_enabled ? module.storage[0].rds_security_group_id : ""
  storage_elasticache_security_group_id = local.storage_enabled ? module.storage[0].elasticache_security_group_id : ""

  # Pass compute instance role (for attaching ECR permissions)
  instance_role_name = local.compute_enabled ? module.compute[0].instance_role_name : ""

  # Pass EKS node role for ECR permissions (if EKS is used)
  eks_node_role_name = local.compute_enabled ? module.compute[0].eks_node_role_name : ""

  # Pass kubeconfig readiness marker to ensure kubectl context exists before K8s operations
  kubeconfig_ready = local.compute_enabled ? module.compute[0].kubeconfig_ready : {}

  # Pass EKS cluster security groups for storage access rules
  eks_cluster_security_groups = local.compute_enabled ? module.compute[0].eks_cluster_security_groups : {}
}

# Legacy Module
# Disposable Atlantis deployment - proof of cattle-style infrastructure
module "legacy" {
  count  = local.legacy_enabled ? 1 : 0
  source = "./legacy"

  # Pass cross-account provider for secrets access
  providers = {
    aws.prod = aws.prod
  }

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id

  # Service-specific configuration (defaults handled by module)
  config = module.config.service_configs["legacy"]

  # Access return-path (IAM resources created by access module)
  access_iam_role_arns          = module.access.iam_role_arns
  access_iam_role_names         = module.access.iam_role_names
  access_instance_profile_names = module.access.instance_profile_names
}

# Secrets Module
# Cross-account secret replication into the deployment account
module "secrets" {
  count  = local.secrets_enabled ? 1 : 0
  source = "./secrets"

  providers = {
    aws                = aws
    aws.infrastructure = aws.infrastructure
    aws.prod           = aws.prod
  }

  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  config         = module.config.service_configs["secrets"]
}

# ClaireVoyance Module
# Medical AI platform on SageMaker - sourced from hackathon-8 repository (improve-compat branch)
module "clairevoyance" {
  count  = 0 # Disabled: upstream module (hackathon-8) not bundled in this repo
  source = "./clairevoyance"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_region     = module.workspaces.aws_region
  aws_profile    = module.workspaces.aws_profile

  # Service-specific configuration (defaults handled by module)
  config = module.config.service_configs["clairevoyance"]
}

# archbot -> arcbot rename: keep existing state addressed under the new module name
# so resources whose AWS names did NOT embed "archbot" are not needlessly recreated.
# (Resources with embedded names still replace - that rename is intentional.)
moved {
  from = module.archbot
  to   = module.arcbot
}

# Legacy module renames (ported examples; normally unused, blocks are no-ops
# when no state exists but protect any deployment that does have them):
moved {
  from = module.archpacs
  to   = module.iopacs
}

moved {
  from = module.archshare
  to   = module.ioshare
}

moved {
  from = module.archorchestrator
  to   = module.iorchestrator
}
