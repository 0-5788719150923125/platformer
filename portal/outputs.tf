output "entity_count" {
  description = "Number of Port.io entities created"
  value       = length(port_entity.compute_instance)
}

output "entity_identifiers" {
  description = "List of created entity identifiers"
  value       = [for entity in port_entity.compute_instance : entity.identifier]
}

output "portal_url" {
  description = "URL to view namespace-scoped page in Port.io"
  value       = "https://app.us.getport.io/platformer-${var.namespace}"
}

output "page_identifier" {
  description = "Port.io page identifier"
  value       = "platformer-${var.namespace}"
}

output "lambda_requests" {
  description = "Scheduled Lambda definitions for configuration-management module to create"
  value       = local.patch_compliance_lambda_request
}

output "event_bus_webhooks" {
  description = "Event bus webhook URLs by purpose (modules post events here)"
  value = {
    for purpose, webhook in port_webhook.event_bus :
    purpose => webhook.url
  }
}
