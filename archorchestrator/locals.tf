# ArchOrchestrator Module Locals
# Deployment iteration model + container image resolution

locals {
  # All unique tenants across all deployments
  all_tenants = distinct(flatten(values(var.tenants_by_deployment)))

  # Network selection per deployment (default to first available network)
  network_by_deployment = {
    for name, config in var.config :
    name => var.networks[coalesce(config.network, keys(var.networks)[0])]
  }

  # Feature flags (across all deployments)
  rds_enabled = anytrue([for _, config in var.config : config.rds != null])
  s3_enabled  = anytrue([for _, config in var.config : length(config.s3) > 0])

  # Service-specific environment variable defaults
  # Synthesized based on service name and deployment context
  service_env_defaults = {
    saasapp = {
      SPRINGBOOT_PROFILES       = "saas"
      BOOTSTRAP_INSTANCE_DOMAIN = "io.local" # Spring Boot bootstrap property
      BOOTSTRAP_CELL_ID         = "default"  # Cell identifier for multi-cell deployments
    }
    router   = {} # Router env vars are deployment-specific, synthesized below
    coreapps = {}
  }

  # Flatten ECS services across all deployments for resource creation
  # Key: "deployment/service" (e.g., "dev1/saasapp")
  # Merges user-provided environment variables with auto-synthesized defaults
  ecs_services = merge([
    for deploy_name, config in var.config : {
      for svc_name, svc_config in config.ecs :
      "${deploy_name}/${svc_name}" => {
        deployment    = deploy_name
        service       = svc_name
        cpu           = svc_config.cpu
        memory        = svc_config.memory
        desired_count = svc_config.desired_count
        port          = svc_config.port
        architecture  = svc_config.architecture
        protocol      = svc_config.protocol
        # Merge: service defaults + deployment-specific synthesis + user overrides
        environment = merge(
          # 1. Service-specific defaults (e.g., saasapp SPRINGBOOT_PROFILES)
          lookup(local.service_env_defaults, svc_name, {}),
          # 2. Deployment-specific synthesis (router configuration with dynamic values)
          svc_name == "router" ? {
            INSTANCE_DOMAIN_NAME      = "${deploy_name}.io.local"
            SAASAPP_TENANT_BUCKET      = try(var.s3_buckets["${deploy_name}-configuration"], "")
            SAASAPP_TENANT_MAPPING_KEY = "router/tenant-mapping.json"
            SAASAPP_DNS_TEMPLATE       = "saasapp.${deploy_name}.io.local:30000"
          } : {},
          # 3. User-provided overrides from state fragment (highest priority)
          svc_config.environment
        )
        image_tag             = svc_config.image
        ecr_source_profile    = config.ecr_source_profile
        ecr_source_account_id = config.ecr_source_account_id
        ecr_source_region     = config.ecr_source_region
        ecr_source_repo       = config.ecr_source_repo
      }
    }
  ]...)

  # Unique image tags across all services (for ECR replication)
  unique_image_tags = distinct([for svc in local.ecs_services : svc.image_tag])

  # Container image URI resolution  -  points to local ECR repo (replicated from source)
  container_images = {
    for key, svc in local.ecs_services :
    key => "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.namespace}-io:${svc.image_tag}"
  }
}
