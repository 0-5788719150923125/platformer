# ArchPACS Module Locals
# Deployment x tenant iteration model + Maestro orchestration

locals {
  # All deployment-tenant pairs (the fundamental iteration unit)
  deployment_tenants = flatten([
    for deploy_name, config in var.config : [
      for tenant in lookup(var.tenants_by_deployment, deploy_name, []) : {
        deployment = deploy_name
        tenant     = tenant
      }
    ]
  ])

  # Keyed by "deployment/tenant" for for_each usage
  deployment_tenant_map = {
    for dt in local.deployment_tenants :
    "${dt.deployment}/${dt.tenant}" => dt
  }

  # All unique tenants across all deployments
  all_tenants = distinct(flatten(values(var.tenants_by_deployment)))

  # Network selection per deployment (use first available network)
  network_by_deployment = {
    for name, config in var.config :
    name => var.networks[keys(var.networks)[0]]
  }

  # Feature flags (across all deployments)
  rds_enabled = anytrue([for _, config in var.config : config.rds != null])
  s3_enabled  = anytrue([for _, config in var.config : config.s3 != null])

  # ── Maestro orchestration ──────────────────────────────────────────────

  # Deployments that have Maestro configuration
  maestro_deployments = {
    for deploy_name, config in var.config :
    deploy_name => config.maestro
    if config.maestro != null
  }
}
