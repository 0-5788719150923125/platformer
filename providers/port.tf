# Port.io (portal backend)
#
# Linked into the root as provider_port.tf by scripts/providers.sh, only in
# workspaces that set port_enabled = true. Port's provider logs in during setup,
# so it can't sit in the always-on providers.tf: every workspace would fail
# without Port credentials. Here it loads only where it's asked for, and the
# portal module (its only user) comes with it.
#
# Port access is currently gone; this is kept so the work isn't lost and for
# anyone who has access. A self-hosted backend (Backstage) is the planned
# replacement - see next/roadmap.md.

# Credentials
# Credentials retrieved from AWS Secrets Manager (only in example-platform-dev account)

data "aws_caller_identity" "port_check" {
  count    = local.prod_provider_configured ? 1 : 0
  provider = aws.prod
}

data "aws_secretsmanager_secret_version" "port_credentials" {
  count     = local.prod_provider_configured && try(data.aws_caller_identity.port_check[0].account_id, "") == "111111111111" ? 1 : 0
  secret_id = "arn:aws:secretsmanager:us-east-2:111111111111:secret:port/prod/credentials-SzPvSL"
  provider  = aws.prod
}

locals {
  # Fetch Port credentials if available (in correct account), otherwise use dummy values
  # Portal module will only be instantiated when credentials are available
  port_credentials = length(data.aws_secretsmanager_secret_version.port_credentials) > 0 ? jsondecode(data.aws_secretsmanager_secret_version.port_credentials[0].secret_string) : {
    client_id     = "dummy-client-id"
    client_secret = "dummy-client-secret"
    org_id        = "dummy-org-id"
  }
}

provider "port" {
  client_id = local.port_credentials.client_id
  secret    = local.port_credentials.client_secret
  base_url  = "https://api.us.getport.io"
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
  state_files               = module.config.available_states
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
