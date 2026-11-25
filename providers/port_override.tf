# Adds the Port provider to the root's required_providers (providers.tf) and
# points core's portal locals (main.tf) at the portal module. Linked into the
# root as provider_port_override.tf by scripts/providers.sh.

terraform {
  required_providers {
    port = {
      source  = "port-labs/port-labs"
      version = "~> 2.0"
    }
  }
}

locals {
  portal_lambda_requests    = local.portal_enabled ? module.portal[0].lambda_requests : []
  portal_event_bus_webhooks = local.portal_enabled ? module.portal[0].event_bus_webhooks : {}
}
