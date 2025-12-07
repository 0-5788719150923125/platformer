# Tenants Module Outputs
# Provides validation interfaces for consumer modules

output "tenants" {
  description = "Full tenant registry (all tenants)"
  value       = local.tenants
}

output "active_tenants" {
  description = "Active tenants only"
  value       = local.active_tenants
}

output "active_tenant_codes" {
  description = "List of active tenant codes (for validation in consumer modules)"
  value       = sort(local.active_tenant_codes)
}

output "tenant_count" {
  description = "Statistics about tenant registry"
  value = {
    total  = length(local.tenants)
    active = length(local.active_tenants)
  }
}

# Entitlement outputs

output "tenants_by_service" {
  description = "Map of service name to entitled tenant code list"
  value       = local.tenants_by_service
}

output "effective_entitlements" {
  description = "Resolved entitlements map (tenant code => service list)"
  value       = local.effective_entitlements
}

output "tenants_by_class" {
  description = "Map of class name to entitled tenant code list (resolves bare and scoped entitlements)"
  value       = local.tenants_by_class
}
