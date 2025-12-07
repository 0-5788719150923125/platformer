# Event Bus Webhooks
# Generic webhook system for infrastructure lifecycle events
# Modules request webhooks via dependency inversion (event_bus_requests)

# Collect event bus requests from all modules via dependency inversion
locals {
  event_bus_requests = concat(
    var.event_bus_requests
  )

  # Convert to map for for_each
  event_bus_webhooks = {
    for req in local.event_bus_requests : req.purpose => req
  }
}

# Create webhook for each event bus subscription request
resource "port_webhook" "event_bus" {
  for_each = local.event_bus_webhooks

  # Hash the purpose to keep identifier under 30 chars: "eb-<hash>-<namespace>"
  identifier = "eb-${substr(md5(each.key), 0, 8)}-${var.namespace}"
  title      = "EB: ${each.value.event_type}"
  icon       = "Webhook"
  enabled    = true

  mappings = [
    {
      blueprint = local.bp_event_bus
      operation = {
        type = "create"
      }
      filter = ".body.event_type != null"
      entity = {
        identifier = ".body.event_id"
        title      = ".body.message"
        team       = jsonencode(var.teams)
        properties = {
          eventType    = ".body.event_type"
          source       = ".body.source"
          status       = ".body.status"
          message      = ".body.message"
          timestamp    = ".body.timestamp"
          resourceId   = ".body.resource_id"
          resourceName = ".body.resource_name"
          awsUrl       = ".body.aws_url"
          duration     = ".body.duration | tonumber?"
          details      = ".body.details"
          errorMessage = ".body.error_message"
          triggeredBy  = ".body.triggered_by"
          namespace    = ".body.namespace"
          workspace    = "\"${var.namespace}\""
        }
      }
    }
  ]

  depends_on = [port_blueprint.event_bus]
}
