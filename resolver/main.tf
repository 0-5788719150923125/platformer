# Resolver Module
# Analyzes service configurations to determine which modules need to be enabled
# Handles both explicit configuration and implicit dependencies

locals {
  # Configuration Management Analysis
  # Check if config-mgmt needs storage (for SSM logs, baselines, or maintenance windows)
  config_mgmt_config         = lookup(var.service_configs, "configuration-management", {})
  config_mgmt_has_ssm_logs   = lookup(local.config_mgmt_config, "s3_output_bucket_enabled", false)
  config_mgmt_patch_mgmt     = lookup(local.config_mgmt_config, "patch_management", {})
  config_mgmt_has_baselines  = length(lookup(local.config_mgmt_patch_mgmt, "baselines", {})) > 0
  config_mgmt_has_maint_wins = length(lookup(local.config_mgmt_patch_mgmt, "maintenance_windows", [])) > 0
  config_mgmt_needs_storage  = local.config_mgmt_has_ssm_logs || local.config_mgmt_has_baselines || local.config_mgmt_has_maint_wins

  # Applications Analysis
  # Check if any top-level compute classes declare applications (dependency inversion)
  compute_config  = lookup(var.service_configs, "compute", {})
  compute_classes = local.compute_config
  compute_has_applications = anytrue([
    for class_name, class_config in local.compute_classes :
    length(lookup(class_config, "applications", [])) > 0
  ])

  # Check if archshare/archpacs deployments declare applications in their compute config
  # Archshare: deployment model  -  each deployment has its own compute object
  archshare_has_apps = anytrue([
    for name, deploy in try(var.service_configs["archshare"], {}) :
    length(try(deploy.compute.applications, [])) > 0
  ])
  # Archpacs: deployment model  -  each deployment has its own compute map
  archpacs_has_apps = anytrue(flatten([
    for _, deploy in try(var.service_configs["archpacs"], {}) : [
      for _, class_config in try(deploy.compute, {}) :
      length(try(class_config.applications, [])) > 0
    ]
  ]))

  # Check if any archshare deployment uses EKS (generates Helm applications)
  archshare_eks_enabled = (
    contains(keys(var.service_configs), "archshare") &&
    anytrue([
      for name, deploy in var.service_configs["archshare"] :
      try(deploy.compute.type, "ec2") == "eks"
    ])
  )

  # Standalone applications: declared directly under services.applications (not inside compute)
  standalone_applications_exist = contains(keys(var.service_configs), "applications")

  applications_needs_storage = local.compute_has_applications || local.archshare_eks_enabled || local.archshare_has_apps || local.archpacs_has_apps || local.standalone_applications_exist


  # Module Requirements Map
  # Each module's enable logic: explicitly configured OR implicitly needed by another module
  module_requirements = {
    storage = (
      contains(keys(var.service_configs), "storage") ||
      local.config_mgmt_needs_storage ||
      local.applications_needs_storage ||
      contains(keys(var.service_configs), "archshare") ||        # Archshare needs RDS+ElastiCache+S3
      contains(keys(var.service_configs), "archpacs") ||         # ArchPACS needs RDS+S3
      contains(keys(var.service_configs), "archorchestrator") || # ArchOrchestrator needs RDS+S3
      contains(keys(var.service_configs), "observability")       # Observability needs S3 for Loki
    )

    compute = (
      contains(keys(var.service_configs), "compute") ||
      contains(keys(var.service_configs), "configuration-management") ||
      # Auto-enable when archshare deployments have compute definitions
      anytrue([
        for _, deploy in try(var.service_configs["archshare"], {}) :
        try(deploy.compute, null) != null
      ]) ||
      # Auto-enable when archpacs deployments have compute definitions
      anytrue([
        for _, deploy in try(var.service_configs["archpacs"], {}) :
        try(deploy.compute, null) != null
      ]) ||
      # Auto-enable when archorchestrator exists (needs ECS clusters)
      contains(keys(var.service_configs), "archorchestrator") ||
      # Auto-enable when observability defines an EKS cluster
      contains(keys(var.service_configs), "observability")
    )

    # Auto-enable when explicitly configured, or when any module declares applications
    # that need the ansible-controller CodeBuild project or SSM associations to deploy
    configuration_management = (
      contains(keys(var.service_configs), "configuration-management") ||
      local.compute_has_applications ||
      local.archshare_has_apps ||
      local.archpacs_has_apps ||
      local.standalone_applications_exist ||
      contains(keys(var.service_configs), "observability") # Alloy agent via Ansible
    )
    domains          = contains(keys(var.service_configs), "domains")
    secrets          = contains(keys(var.service_configs), "secrets")
    legacy           = contains(keys(var.service_configs), "legacy")
    clairevoyance    = contains(keys(var.service_configs), "clairevoyance")
    archshare        = contains(keys(var.service_configs), "archshare")
    archpacs         = contains(keys(var.service_configs), "archpacs")
    archorchestrator = contains(keys(var.service_configs), "archorchestrator")

    # Applications auto-enables when any compute classes declare applications,
    # when archshare with EKS deployment exists (generates Helm applications),
    # or when standalone applications are declared directly under services.applications
    applications = (
      local.compute_has_applications ||
      local.archshare_eks_enabled ||
      local.archshare_has_apps ||
      local.archpacs_has_apps ||
      local.standalone_applications_exist ||
      contains(keys(var.service_configs), "observability") # Helm charts + Alloy agent
    )

    # Observability: explicitly configured
    observability = contains(keys(var.service_configs), "observability")

    # Portal requires explicit opt-in (not auto-enabled)
    # Supports services.portal.enabled: false to disable without removing the key
    portal = contains(keys(var.service_configs), "portal") && try(var.service_configs["portal"].enabled, true)

    # archbot: event-driven AI automation pipeline (Jira-bot and future interfaces)
    archbot = contains(keys(var.service_configs), "archbot")
  }
}
