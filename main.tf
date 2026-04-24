# Current region and account data sources (only when AWS is configured)
data "aws_region" "current" {
  count = local.aws_configured ? 1 : 0
}

data "aws_caller_identity" "current" {
  count = local.aws_configured ? 1 : 0
}

locals {
  # Convenience aliases — fall back to variable values when AWS is not configured
  aws_account_id = local.aws_configured ? data.aws_caller_identity.current[0].account_id : "not-configured"
  aws_region     = local.aws_configured ? data.aws_region.current[0].id : module.workspaces.aws_region

  # Module enable flags from resolver module
  # Resolver analyzes service configs and determines which modules to enable
  # Storage requires AWS - disabled when aws_profile is null
  storage_enabled                  = local.aws_configured
  compute_enabled                  = module.resolver.compute
  configuration_management_enabled = module.resolver.configuration_management
  applications_enabled             = module.resolver.applications
  domains_enabled                  = module.resolver.domains
  secrets_enabled                  = module.resolver.secrets
  legacy_enabled                   = module.resolver.legacy
  clairevoyance_enabled            = module.resolver.clairevoyance
  archshare_enabled                = module.resolver.archshare
  archpacs_enabled                 = module.resolver.archpacs
  archorchestrator_enabled         = module.resolver.archorchestrator
  portal_enabled                   = module.resolver.portal
  observability_enabled            = module.resolver.observability
  archbot_enabled                  = module.resolver.archbot

  # Effective compute config: merge top-level compute with module-emitted compute classes
  # Modules like archshare/archpacs/archorchestrator define compute classes internally and emit them
  effective_compute_config = merge(
    lookup(module.config.service_configs, "compute", {}),
    local.archshare_enabled ? module.archshare[0].compute_class_requests : {},
    local.archpacs_enabled ? module.archpacs[0].compute_class_requests : {},
    local.archorchestrator_enabled ? module.archorchestrator[0].compute_class_requests : {},
    local.observability_enabled ? module.observability[0].compute_class_requests : {}
  )

  # Expand archpacs deployment entitlements to individual compute class names
  # Archpacs has multiple compute classes per deployment (e.g., depot, database)
  # Entitlement "archpacs.ec2-poc" maps to tenants_by_class["ec2-poc"]
  # But compute classes are named "ec2-poc-depot", "ec2-poc-database"  -  need expansion
  archpacs_compute_class_tenants = local.archpacs_enabled ? merge([
    for deploy_name in try(keys(module.config.service_configs["archpacs"]), []) : {
      for class_name in try(keys(module.config.service_configs["archpacs"][deploy_name].compute), []) :
      "${deploy_name}-${class_name}" => try(module.tenants.tenants_by_class[deploy_name], [])
    }
  ]...) : {}

  # Observability EKS cluster is infrastructure, not tenant-facing
  # Inject a synthetic "platform" entry so compute doesn't filter it out
  observability_cluster_tenants = local.observability_enabled ? {
    "observability" = ["platform"]
  } : {}

  # ArchOrchestrator ECS cluster entitlements
  # Map cluster purpose (e.g., "dev1-io") to tenants entitled to that deployment
  archorchestrator_cluster_tenants = local.archorchestrator_enabled ? {
    for deploy_name in try(keys(module.config.service_configs["archorchestrator"]), []) :
    "${deploy_name}-io" => try(module.tenants.tenants_by_class[deploy_name], [])
  } : {}

  # ── Alloy Kubernetes fan-out ─────────────────────────────────────────
  # Non-observability EKS class names for Alloy DaemonSet deployment
  non_obs_eks_class_names = [
    for class_name, class_config in local.effective_compute_config :
    class_name
    if try(class_config.type, "") == "eks" && class_name != "observability"
  ]

  # Fan out the Alloy Helm template to every non-observability EKS cluster
  # Replaces LOKI_PUSH_ENDPOINT, MIMIR_REMOTE_WRITE_ENDPOINT with NLB DNS and CLUSTER_NAME with class name
  alloy_external_helm_requests = local.observability_enabled && module.observability[0].alloy_helm_template != null ? [
    for class_name in local.non_obs_eks_class_names :
    merge(module.observability[0].alloy_helm_template, {
      class = class_name
      values = replace(
        replace(
          replace(
            module.observability[0].alloy_helm_template.values,
            "LOKI_PUSH_ENDPOINT",
            "http://${module.compute[0].lb_dns_names["observability-loki-gateway"]}:80/loki/api/v1/push"
          ),
          "CLUSTER_NAME",
          class_name
        ),
        "MIMIR_REMOTE_WRITE_ENDPOINT",
        try("http://${module.compute[0].lb_dns_names["observability-mimir"]}:80/api/v1/push", "http://localhost:9009/api/v1/push")
      )
    })
  ] : []

  # Fan out kube-state-metrics to every non-observability EKS cluster
  ksm_external_helm_requests = local.observability_enabled && module.observability[0].kube_state_metrics_helm_template != null ? [
    for class_name in local.non_obs_eks_class_names :
    merge(module.observability[0].kube_state_metrics_helm_template, {
      class = class_name
    })
  ] : []

  # Fan out prometheus-node-exporter to every non-observability EKS cluster
  node_exporter_external_helm_requests = local.observability_enabled && module.observability[0].prometheus_node_exporter_helm_template != null ? [
    for class_name in local.non_obs_eks_class_names :
    merge(module.observability[0].prometheus_node_exporter_helm_template, {
      class = class_name
    })
  ] : []

  # Config-derived: are there ansible application requests?
  # Uses applications module requests (config-derived, no resource dependencies) to avoid
  # the cycle: cluster_application_requests -> aws_instance.tenant -> access -> access_requests
  ansible_applications_configured = local.applications_enabled && length([
    for req in flatten([for m in module.applications : m.requests]) :
    req if try(req.type, "") == "ansible"
  ]) > 0

  # Event bus webhook requests (dependency inversion)
  event_bus_requests = concat(
    local.configuration_management_enabled ? module.configuration_management[0].event_bus_requests : [],
    local.archbot_enabled ? module.archbot[0].event_bus_requests : []
  )

  # Shared portal namespace - non-default workspaces inherit the default workspace's namespace
  # so all workspaces share a single Port.io catalog and blueprint set.
  # AWS resources (S3, IAM, SQS, etc.) continue using module.namespace.id (workspace-specific)
  # to avoid name collisions between workspaces.
  # coalesce(try(...), ...) handles two cases:
  # 1. Default workspace (count=0): splat produces [], one([]) returns null → falls through
  # 2. Non-default workspace where default state has no outputs yet: try() returns null → falls through
  subspace = coalesce(
    try(one(data.terraform_remote_state.default_workspace[*]).outputs.deployment_id, null),
    module.namespace.id
  )
}

# Deployment namespace for resource isolation
module "namespace" {
  source = "./hashing"

  algorithm = "pokeform"
}

# Cross-workspace namespace inheritance
# When running in a non-default workspace, read the default workspace's deployed namespace.
# This allows archbot, praxis, and other named workspaces to share the same Port.io catalog
# and namespace-scoped resources as the default workspace instead of creating isolated duplicates.
# Prerequisite: the default workspace must have been applied at least once (terraform.tfstate must exist).
data "terraform_remote_state" "default_workspace" {
  count = module.workspaces.is_default_workspace ? 0 : 1

  backend = "local"
  config = {
    path = "${path.root}/terraform.tfstate"
  }
}

# Auto-documentation - Generates SCHEMA.md from all variables.tf files
module "auto_docs" {
  source = "./auto-docs"
}

# Access Module - Centralized access control reporting
# Always-on. Aggregates IAM roles, security groups, and resource policies from all
# modules into a JSON report in AWS-native format. Emits artifact_requests for the
# portal artifact catalog.
module "access" {
  source = "./access"

  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region

  # IAM access requests (dependency inversion - access creates IAM resources)
  # Conditions must be config-derived (not length(module.X)) to avoid module-closure cycles
  access_requests = concat(
    local.compute_enabled ? module.compute[0].access_requests : [],
    local.compute_enabled ? module.build[0].access_requests : [],
    local.archorchestrator_enabled ? module.archorchestrator[0].access_requests : [],
    local.archbot_enabled ? module.archbot[0].access_requests : [],
    local.legacy_enabled ? module.legacy[0].access_requests : [],
    local.configuration_management_enabled ? module.configuration_management[0].access_requests : [],
  )

  # V2 IAM role descriptions (modules not yet migrated to access_requests)
  iam_roles = []

  security_groups = concat(
    local.compute_enabled ? module.compute[0].access_security_groups : [],
    local.storage_enabled ? module.storage[0].access_security_groups : [],
    local.archpacs_enabled ? module.archpacs[0].access_security_groups : [],
    local.archorchestrator_enabled ? module.archorchestrator[0].access_security_groups : [],
  )

  resource_policies = concat(
    local.storage_enabled ? module.storage[0].access_resource_policies : [],
    local.archbot_enabled ? module.archbot[0].access_resource_policies : [],
  )
}

# Archivist - Produces a scrubbed, versioned archive of the platformer codebase
# Always-on. Emits bucket_requests (consumed by storage) and artifact_requests (consumed by portal).
# Bucket name is computed directly here to avoid a module cycle with storage.
module "archivist" {
  source = "./archivist"

  bucket_name = "archivist-${module.namespace.id}"
  repo_name   = "archivist-${module.namespace.id}"
  aws_profile = module.workspaces.aws_profile != null ? module.workspaces.aws_profile : ""
  aws_region  = local.aws_region
  states      = module.workspaces.states

  # Access report upload - archivist coordinates the upload once both the
  # report file (access module) and its bucket (storage module) are ready.
  report_path        = module.access.report_path
  report_ready       = module.access.report_ready
  report_bucket_name = local.storage_enabled ? module.storage[0].bucket_names["access-report"] : ""
}

# Workspaces Module - Workspace-specific variable resolution
# Loads terraform.tfvars.{workspace} files for environment-specific overrides
# Falls back to base terraform.tfvars when workspace file doesn't exist
module "workspaces" {
  source = "./workspaces"

  # Pass base terraform.tfvars values as defaults
  default_aws_profile = var.aws_profile
  default_aws_region  = var.aws_region
  default_states      = var.states
  default_owner       = var.owner

  # Disable workspace file overrides in tests
  enabled = var.workspace_overrides
}

# Config Module - Resolves final service configuration
# Loads and merges state fragments (single source of truth)
module "config" {
  source = "./config"

  states      = module.workspaces.states
  states_dirs = ["../states", "../tests/states"]
  aws_region  = module.workspaces.aws_region
}

# Resolver Module - Dependency resolution
# Analyzes service configurations to determine which modules need to be enabled (auto-enable logic)
module "resolver" {
  source = "./resolver"

  service_configs = module.config.service_configs
}

# Tenants Module - Central tenant registry, validation, and entitlement resolution
# Always enabled - provides validation data and tenant-by-service lists for other modules
module "tenants" {
  source = "./tenants"

  config = lookup(module.config.matrix_configs, "tenants", {})

  # Class names per service (for resolving entitlements to deployment-level granularity)
  # Deployment names ARE class names for entitlement resolution
  service_class_names = {
    compute          = try(keys(module.config.service_configs["compute"]), [])
    archshare        = try(keys(module.config.service_configs["archshare"]), [])
    archpacs         = try(keys(module.config.service_configs["archpacs"]), [])
    archorchestrator = try(keys(module.config.service_configs["archorchestrator"]), [])
  }
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

# Domains Module
# Route53 zone lookup + ACM wildcard certificate with DNS validation
module "domains" {
  count  = local.domains_enabled ? 1 : 0
  source = "./domains"

  namespace = module.namespace.id
  config    = module.config.service_configs["domains"]
}

# Networking Module
# VPC, subnet, and gateway management with deterministic CIDR allocation
# Supports multiple named networks for VPC isolation
# If no networks defined, auto-create a "default" network using AWS default VPC
module "networks" {
  for_each = local.aws_configured ? lookup(module.config.service_configs, "networks", { default = { allocation_method = "default" } }) : {}
  source   = "./networking"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  network_name   = each.key

  # Service-specific configuration
  config = each.value
}

# Storage Module
# S3 bucket, RDS, ElastiCache provisioning with dependency inversion pattern
module "storage" {
  count  = local.storage_enabled ? 1 : 0
  source = "./storage"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_profile    = module.workspaces.aws_profile
  aws_region     = local.aws_region

  # Collect bucket request definitions from all modules (dependency inversion pattern)
  # Modules define bucket requirements; storage module creates aws_s3_bucket resources
  bucket_requests = concat(
    module.archivist.bucket_requests,
    module.access.bucket_requests,
    local.configuration_management_enabled ? module.configuration_management[0].bucket_requests : [],
    local.archshare_enabled ? module.archshare[0].bucket_requests : [],
    local.archshare_enabled ? [module.archshare[0].ansible_bucket_request] : [],
    local.archpacs_enabled ? module.archpacs[0].bucket_requests : [],
    local.archorchestrator_enabled ? module.archorchestrator[0].bucket_requests : [],
    local.observability_enabled ? module.observability[0].bucket_requests : [],
    local.archbot_enabled ? module.archbot[0].bucket_requests : [],
  )

  # Collect RDS cluster/instance request definitions from all modules (dependency inversion pattern)
  # Unified interface supports both Aurora clusters (type = "aurora") and standalone instances (type = "standalone")
  # Modules define RDS requirements; storage module creates resources based on type
  rds_cluster_requests = concat(
    local.archshare_enabled ? module.archshare[0].rds_cluster_requests : [],
    local.archpacs_enabled ? module.archpacs[0].rds_cluster_requests : [],
    local.archorchestrator_enabled ? module.archorchestrator[0].rds_cluster_requests : []
    # Future modules can add RDS requests here
  )

  # Collect ElastiCache cluster request definitions from all modules (dependency inversion pattern)
  # Modules define ElastiCache requirements; storage module creates ElastiCache resources
  elasticache_cluster_requests = concat(
    local.archshare_enabled ? module.archshare[0].elasticache_cluster_requests : []
    # Future modules can add ElastiCache requests here
  )

  # Collect CodeCommit repository request definitions from all modules (dependency inversion pattern)
  # Modules define repository requirements; storage module creates CodeCommit resources
  repository_requests = concat(
    module.archivist.repository_requests
    # Future modules can add repository requests here
  )

  # Collect EBS volume request definitions from all modules (dependency inversion pattern)
  # Compute emits one request per (instance × declared volume); storage owns
  # both the aws_ebs_volume and the aws_volume_attachment.
  volume_requests = concat(
    local.compute_enabled ? module.compute[0].volume_requests : []
    # Future modules can add volume requests here
  )
}

# Build Module
# Golden AMI builds  -  sits between storage and compute in the dependency graph
# Needs: storage (for application-scripts bucket), config (for class definitions)
# Produces: built AMI IDs consumed by compute for instance launches
module "build" {
  count  = local.compute_enabled ? 1 : 0
  source = "./build"

  namespace                  = module.namespace.id
  aws_profile                = module.workspaces.aws_profile
  config                     = local.effective_compute_config
  standalone_applications    = lookup(module.config.service_configs, "applications", {})
  vpc_id                     = module.networks[keys(module.networks)[0]].network_summary.vpc_id
  subnet_id                  = module.networks[keys(module.networks)[0]].subnets_by_tier["public"].ids[0]
  application_scripts_bucket = local.storage_enabled && contains(keys(module.storage[0].bucket_names), "application-scripts") ? module.storage[0].bucket_names["application-scripts"] : ""

  # Access return-path (IAM resources managed by access module)
  access_iam_role_names         = module.access.iam_role_names
  access_instance_profile_names = module.access.instance_profile_names
}

# Compute Module
# Tenant instance management with kind-based templates
module "compute" {
  count  = local.compute_enabled ? 1 : 0
  source = "./compute"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_profile    = module.workspaces.aws_profile

  # Service-specific configuration (defaults handled by module)
  # Merges top-level compute classes with module-emitted compute classes
  config = local.effective_compute_config

  # Domain configuration (dependency inversion from domains module)
  # domain_enabled is config-derived (plan-time safe)  -  gates for_each on ALB resources
  # The remaining values are resource outputs, used only inside resource bodies
  domain_enabled         = local.domains_enabled
  domain_zone_id         = local.domains_enabled ? module.domains[0].zone_id : ""
  domain_zone_name       = local.domains_enabled ? module.domains[0].zone_name : ""
  domain_certificate_arn = local.domains_enabled ? module.domains[0].certificate_arn : ""
  domain_aliases         = local.domains_enabled ? module.domains[0].aliases : {}

  # Access return-path (IAM resources managed by access module)
  access_iam_role_arns          = module.access.iam_role_arns
  access_iam_role_names         = module.access.iam_role_names
  access_instance_profile_names = module.access.instance_profile_names

  # Built AMIs from build module (golden AMI IDs for classes with build: true)
  built_amis = local.compute_enabled && length(module.build) > 0 ? module.build[0].built_amis : {}

  # Standalone applications for ImageBuilder golden AMI inclusion
  # ImageBuilder matches standalone apps to build classes by targeting mode (wildcard/tags/compute)
  standalone_applications = lookup(module.config.service_configs, "applications", {})

  # Per-class tenant lists from entitlements
  # Merge base entitlements with expanded archpacs deployment→class mappings and archorchestrator ECS clusters
  tenants_by_class = merge(
    module.tenants.tenants_by_class,
    local.archpacs_compute_class_tenants,
    local.archorchestrator_cluster_tenants,
    local.observability_cluster_tenants
  )

  # Network module outputs (dependency inversion)
  # Pass all networks - compute resolves which network to use per class
  networks = module.networks

  # Tenant validation from tenants module (dependency inversion)
  # Ensures only active, registered tenants can be targeted
  valid_tenants = module.tenants.active_tenant_codes

  # Collect instance parameter definitions from all modules (dependency inversion pattern)
  # Modules define parameters; compute module creates aws_ssm_parameter resources
  # Implicit dependency: Terraform tracks resource references in parameter definitions
  instance_parameters = concat(
    local.configuration_management_enabled ? module.configuration_management[0].instance_parameters : []
    # Future modules can add parameter definitions here
  )

  # Pass patch group mappings from configuration-management module (dependency inversion)
  # Used to tag instances with correct namespaced patch group for patch management
  patch_groups_by_class = local.configuration_management_enabled ? module.configuration_management[0].patch_groups_by_class : {}

  # Pass application requests from applications module (dependency inversion)
  # Compute filters internally by type (user-data, helm)
  # Use flatten to handle conditional module existence (count=0 → empty list, count=1 → requests)
  application_requests = flatten([for m in module.applications : m.requests])

  # Pod Identity requests from upstream modules (dependency inversion)
  # Modules emit IAM role + service account bindings; compute creates the associations
  pod_identity_requests = concat(
    local.observability_enabled ? module.observability[0].pod_identity_requests : []
  )

  # NLB requests from upstream modules (dependency inversion)
  # Modules emit NLB requirements; compute creates Terraform-managed load balancers
  lb_requests = concat(
    local.observability_enabled ? module.observability[0].lb_requests : []
  )
}

# Observability Module
# LGTM stack (Loki, Grafana, Tempo, Mimir) - emits compute/storage/application requests
module "observability" {
  count  = local.observability_enabled ? 1 : 0
  source = "./observability"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region

  # Service-specific configuration
  config = module.config.service_configs["observability"]

}

# Portal Module
# Port.io integration for compute instance catalog
# Ephemeral resources - entities created at apply-time, destroyed at destroy-time
module "portal" {
  count  = local.portal_enabled ? 1 : 0
  source = "./portal"

  namespace                 = module.namespace.id
  subspace                  = local.subspace
  is_default_workspace      = module.workspaces.is_default_workspace
  owner                     = module.workspaces.owner
  compute_instances         = local.compute_enabled ? module.compute[0].instances : {}
  eks_clusters              = local.compute_enabled ? module.compute[0].eks_clusters : {}
  ecs_clusters              = local.compute_enabled ? module.compute[0].ecs_clusters : {}
  port_client_id            = local.port_credentials.client_id
  port_secret               = local.port_credentials.client_secret
  port_org_id               = local.port_credentials.org_id
  aws_profile               = var.aws_profile
  commands                  = local.all_commands
  patch_management_enabled  = local.configuration_management_enabled ? module.configuration_management[0].patch_management_enabled : false
  patch_management_by_class = local.configuration_management_enabled ? module.configuration_management[0].patch_management_by_class : {}
  tenant_entitlements       = module.tenants.effective_entitlements
  service_urls              = local.service_urls_filtered
  states                    = module.workspaces.states
  event_bus_requests        = local.event_bus_requests
  artifact_requests = concat(
    module.archivist.artifact_requests,
    local.compute_enabled ? module.build[0].artifact_requests : [],
    module.access.artifact_requests,
  )
  storage_requests = concat(
    local.storage_enabled ? module.storage[0].inventory : [],
  )
}

# Configuration Management Module
# Includes: Windows password rotation, patch management, future compliance scanning, etc.
module "configuration_management" {
  count  = local.configuration_management_enabled ? 1 : 0
  source = "./configuration-management"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_profile    = module.workspaces.aws_profile
  aws_region     = local.aws_region

  # Service-specific configuration (defaults handled by module)
  # May be auto-enabled by standalone applications without explicit configuration-management key
  config = lookup(module.config.service_configs, "configuration-management", {})

  # Whether application deployments exist (computed from config, no runtime dependency)
  # Drives the application-scripts bucket request without creating a cycle through compute
  has_application_deployments = anytrue([
    for class_name, class_config in local.effective_compute_config :
    length(try(class_config.applications, [])) > 0
  ]) || length(lookup(module.config.service_configs, "applications", {})) > 0

  # Pass bucket names from storage module (dependency inversion)
  ssm_association_log_bucket = local.storage_enabled && contains(keys(module.storage[0].bucket_names), "ssm-association-logs") ? module.storage[0].bucket_names["ssm-association-logs"] : ""
  hooks_bucket               = local.storage_enabled && contains(keys(module.storage[0].bucket_names), "hooks") ? module.storage[0].bucket_names["hooks"] : ""

  # Pass instances by class from compute module (dependency inversion)
  instances_by_class = local.compute_enabled ? module.compute[0].instances_by_class : {}

  # Pass application requests from applications module (dependency inversion)
  # Configuration-management filters internally by type (ssm, ansible)
  # Use flatten to handle conditional module existence (count=0 → empty list, count=1 → requests)
  # Cluster requests (mode: 1-master) come directly from compute  -  they reference instance IPs
  # and are already enriched with playbook_source_path, so they bypass the applications module
  application_requests = concat(
    flatten([for m in module.applications : m.requests]),
    local.compute_enabled ? module.compute[0].cluster_application_requests : []
  )

  # Pass application scripts bucket from storage module (dependency inversion)
  application_scripts_bucket = local.storage_enabled && contains(keys(module.storage[0].bucket_names), "application-scripts") ? module.storage[0].bucket_names["application-scripts"] : ""

  # Pass instance role for SSM-based application deployment (IAM policies)
  instances_role_name = local.compute_enabled ? module.compute[0].instance_role_name : ""
  instances_role_arn  = local.compute_enabled ? module.compute[0].instance_role_arn : ""

  # Scheduled Lambda requests from portal module (dependency inversion)
  lambda_requests = local.portal_enabled ? module.portal[0].lambda_requests : []

  # Event bus webhooks from portal module (dependency inversion)
  event_bus_webhooks = local.portal_enabled ? module.portal[0].event_bus_webhooks : {}

  # AWS SSO start URL for console link wrapping
  aws_sso_start_url = var.aws_sso_start_url

  # Config-derived ansible flag (avoids module-closure cycle via cluster_application_requests)
  ansible_applications_configured = local.ansible_applications_configured

  # Access return-path (IAM resources created by access module)
  access_iam_role_arns  = module.access.iam_role_arns
  access_iam_role_names = module.access.iam_role_names
}

# Applications Module
# Purely declarative - defines application requirements
# Auto-enables when compute classes declare applications or standalone applications exist
module "applications" {
  count  = local.applications_enabled ? 1 : 0
  source = "./applications"

  # Dependency inversion: collect application requests from multiple sources
  # Alloy requests get LOKI_ENDPOINT injected from compute's Terraform-managed NLB
  application_requests = concat(
    local.compute_enabled ? module.compute[0].application_requests : [],
    local.archshare_enabled ? module.archshare[0].helm_application_requests : [],
    local.observability_enabled ? module.observability[0].helm_application_requests : [],
    local.observability_enabled ? [
      for req in module.observability[0].alloy_application_requests :
      merge(req, {
        params = merge(req.params, {
          LOKI_ENDPOINT = "http://${module.compute[0].lb_dns_names["observability-loki-gateway"]}:80/loki/api/v1/push"
        })
      })
    ] : [],
    local.alloy_external_helm_requests,
    local.ksm_external_helm_requests,
    local.node_exporter_external_helm_requests
  )

  # Standalone applications config (declared directly under services.applications)
  config = lookup(module.config.service_configs, "applications", {})
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

# Archshare Module
# Medical imaging platform orchestration - generates infrastructure requests for storage module
module "archshare" {
  count  = local.archshare_enabled ? 1 : 0
  source = "./archshare"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id

  # Service-specific configuration (defaults handled by module)
  # Each key is a named deployment containing compute + RDS + ElastiCache config
  config = module.config.service_configs["archshare"]

  # Per-deployment tenant lists (from entitlements system)
  # Deployment name = class name, so tenants_by_class maps deployment → tenants
  tenants_by_deployment = {
    for name in try(keys(module.config.service_configs["archshare"]), []) :
    name => try(module.tenants.tenants_by_class[name], [])
  }

  # Network module outputs (dependency inversion)
  networks = module.networks

  # Pass storage outputs back (dependency inversion return path)
  # Storage module creates resources, then we pass endpoints back to archshare
  rds_clusters         = local.storage_enabled ? module.storage[0].rds_clusters : {}
  elasticache_clusters = local.storage_enabled ? module.storage[0].elasticache_clusters : {}
  s3_buckets           = local.storage_enabled ? module.storage[0].bucket_names : {}
  efs_filesystems      = {} # Not implemented yet

  # Pass storage security group IDs (for archshare to create access rules)
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

# ArchPACS Module
# Medical imaging PACS platform - generates infrastructure requests for compute, storage, and applications
module "archpacs" {
  count  = local.archpacs_enabled ? 1 : 0
  source = "./archpacs"

  # Core variables
  namespace = module.namespace.id

  # Service-specific configuration
  # Each key is a named deployment containing compute + RDS + S3 config
  config = module.config.service_configs["archpacs"]

  # Per-deployment tenant lists (from entitlements system)
  # Deployment name = class name, so tenants_by_class maps deployment → tenants
  tenants_by_deployment = {
    for name in try(keys(module.config.service_configs["archpacs"]), []) :
    name => try(module.tenants.tenants_by_class[name], [])
  }

  # Network module outputs (dependency inversion)
  networks = module.networks
}

# ArchOrchestrator Module
# IO Cloud / SaaSApp platform - ECS Fargate services with MSSQL backend
# Generates infrastructure requests for storage module (RDS SQL Server, S3)
module "archorchestrator" {
  count  = local.archorchestrator_enabled ? 1 : 0
  source = "./archorchestrator"

  # Core variables
  namespace      = module.namespace.id
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region
  aws_profile    = module.workspaces.aws_profile

  # Service-specific configuration
  # Each key is a named deployment (IO Cloud "instance") containing ECS + RDS + S3 config
  config = module.config.service_configs["archorchestrator"]

  # Per-deployment tenant lists (from entitlements system)
  # Deployment name = class name, so tenants_by_class maps deployment → tenants
  tenants_by_deployment = {
    for name in try(keys(module.config.service_configs["archorchestrator"]), []) :
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

# archbot Module
# Event-driven AI automation pipeline - Jira webhook -> SQS -> Lambda -> Devin -> Jira comment
# No dependencies on compute, storage, or networking modules
module "archbot" {
  count  = local.archbot_enabled ? 1 : 0
  source = "./archbot"

  namespace   = module.namespace.id
  config      = module.config.service_configs["archbot"]
  aws_profile = module.workspaces.aws_profile

  # Secrets replicated by the secrets module (dependency inversion)
  atlassian_secret_arn = local.secrets_enabled ? module.secrets[0].replicated_secret_arns["archbot/atlassian_pat"] : ""
  devin_secret_arn     = local.secrets_enabled ? module.secrets[0].replicated_secret_arns["archbot/devin_api_key"] : ""

  # Event bus webhooks from portal module (dependency inversion)
  event_bus_webhooks = local.portal_enabled ? module.portal[0].event_bus_webhooks : {}

  # KB documents bucket from storage module (dependency inversion)
  kb_documents_bucket_name    = local.storage_enabled && contains(keys(module.storage[0].bucket_names), "archbot-kb-docs") ? module.storage[0].bucket_names["archbot-kb-docs"] : ""
  kb_documents_bucket_arn     = local.storage_enabled && contains(keys(module.storage[0].bucket_arns), "archbot-kb-docs") ? module.storage[0].bucket_arns["archbot-kb-docs"] : ""
  kb_documents_bucket_trigger = local.storage_enabled && contains(keys(module.storage[0].bucket_replacement_triggers), "archbot-kb-docs") ? module.storage[0].bucket_replacement_triggers["archbot-kb-docs"] : ""

  # Access return-path (IAM resources created by access module)
  access_iam_role_arns  = module.access.iam_role_arns
  access_iam_role_names = module.access.iam_role_names
}