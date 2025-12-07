# Tenants Module - Central Tenant Registry
# Source of truth for all valid tenant codes across the organization
# Tenant list maintained in tenants.yaml for easy human curation

locals {
  # Load tenant registry from YAML file
  tenant_registry = yamldecode(file("${path.module}/tenants.yaml"))

  # Master tenant registry with metadata
  # All tenants must be defined in tenants.yaml before they can be used in state fragments
  tenants = local.tenant_registry.tenants

  # Derived lists for validation
  active_tenants = {
    for code, attrs in local.tenants :
    code => attrs if attrs.active
  }

  active_tenant_codes = keys(local.active_tenants)

  # ============================================================================
  # Entitlement Resolution
  # ============================================================================
  # Dot-notation syntax:
  #   "compute.*"              → wildcard, tenant gets ALL classes in the service
  #   "compute.windows-server" → scoped, tenant gets only that class
  #   "archshare"            → bare service name (for services without classes)

  # Known service names: auto-discovered from sibling directories containing main.tf
  # Catches typos in entitlements (e.g., "compue" instead of "compute")
  known_services = toset([
    for f in fileset("${path.module}/..", "*/main.tf") :
    dirname(f)
  ])

  # Services that have classes defined (require dot-notation)
  services_with_classes = toset(keys(var.service_class_names))

  # Effective entitlements: filter to active tenants only
  effective_entitlements = {
    for code, attrs in var.config :
    code => attrs.entitlements
    if contains(local.active_tenant_codes, code)
  }

  # Parse entitlements into structured entries with service and class
  entitlement_entries = flatten([
    for code, entitlements in local.effective_entitlements : [
      for ent in entitlements : {
        tenant  = code
        service = split(".", ent)[0]
        class   = length(split(".", ent)) > 1 ? split(".", ent)[1] : null
      }
    ]
  ])

  # Validate: service part must be a known module directory
  _validate_entitlements = [
    for entry in local.entitlement_entries :
    entry if !contains(local.known_services, entry.service)
  ]

  # Tenants by service: any tenant mentioning the service (bare, wildcard, or scoped)
  tenants_by_service = {
    for svc in local.known_services :
    svc => sort(distinct([
      for entry in local.entitlement_entries :
      entry.tenant if entry.service == svc
    ]))
  }

  # Tenants by class: resolve per-class tenant lists
  # Wildcard entitlement (e.g., "compute.*") → tenant gets ALL classes in that service
  # Scoped entitlement (e.g., "compute.windows-server") → tenant gets only that class
  tenants_by_class = merge([
    for svc, class_names in var.service_class_names : {
      for cls in class_names :
      cls => sort(distinct(concat(
        # Tenants explicitly scoped to this class
        [for entry in local.entitlement_entries : entry.tenant if entry.service == svc && entry.class == cls],
        # Tenants with wildcard entitlement (all classes)
        [for entry in local.entitlement_entries : entry.tenant if entry.service == svc && entry.class == "*"]
      )))
    }
  ]...)
}
