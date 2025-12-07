# Service URL Entities
# Creates Port entities for each service URL with tenant mapping
# Enables unified service directory widget showing URLs grouped by tenant

resource "port_entity" "service_url" {
  for_each = var.service_urls

  blueprint  = local.bp_service_url
  identifier = "${each.key}-${var.namespace}"
  title      = "${each.value.service} (${each.value.deployment})"
  teams      = var.teams

  properties = {
    string_props = merge(
      # Required fields
      {
        urlLabel   = each.value.deployment
        tenantList = join(", ", each.value.tenants)
        module     = each.value.module
        deployment = each.value.deployment
        namespace  = var.subspace
        workspace  = var.namespace
      },
      # Conditionally set URL if present
      each.value.url != null ? {
        url = each.value.url
      } : {}
    )
  }

  depends_on = [port_blueprint.service_url]
}
