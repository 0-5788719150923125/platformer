# Port.io Blueprint Permissions
# Scopes all blueprint entity operations to var.teams + Admin role
# This controls who can see, create, update, and delete entities

locals {
  managed_blueprints = {
    documentation      = local.bp_documentation
    git_commit         = local.bp_git_commit
    tenant_entitlement = local.bp_tenant_entitlement
    service_url        = local.bp_service_url
    compute_instance   = local.bp_compute_instance
    state_fragment     = local.bp_state_fragment
    event_bus          = local.bp_event_bus
    artifact           = local.bp_artifact
    storage            = local.bp_storage
  }

  # Reusable permission block scoped to Admin + team
  team_permission = {
    roles         = ["Admin"]
    users         = []
    teams         = var.teams
    owned_by_team = false
  }

  # Page permissions JSON passed to manage-page.sh
  page_permissions_json = jsonencode({
    read = {
      roles = ["Admin"]
      teams = var.teams
    }
  })

  # Action permissions JSON passed to manage-action.sh
  action_permissions_json = jsonencode({
    execute = {
      roles       = ["Admin"]
      users       = []
      teams       = var.teams
      ownedByTeam = false
    }
    approve = {
      roles = ["Admin"]
      users = []
      teams = []
    }
  })
}

# Catalog page title and permission management for auto-generated blueprint pages.
# Port creates a catalog page per blueprint with "open to org" defaults and generic
# titles. This discovers those pages by blueprint identifier, renames them with the
# namespace possessive (e.g. "Zapdos' Artifacts"), and scopes read access to the team.
locals {
  # Possessive prefix: "Zapdos'" vs "Cloco's"
  possessive_prefix = endswith(local.namespace_title, "s") ? "${local.namespace_title}'" : "${local.namespace_title}'s"

  # Map of blueprint identifier -> desired catalog page title
  catalog_page_titles = {
    (local.bp_documentation)      = "${local.possessive_prefix} Documentation"
    (local.bp_git_commit)         = "${local.possessive_prefix} Git Commits"
    (local.bp_tenant_entitlement) = "${local.possessive_prefix} Tenant Entitlements"
    (local.bp_service_url)        = "${local.possessive_prefix} Service URLs"
    (local.bp_compute_instance)   = "${local.possessive_prefix} Compute Instances"
    (local.bp_state_fragment)     = "${local.possessive_prefix} States"
    (local.bp_event_bus)          = "${local.possessive_prefix} Events"
    (local.bp_artifact)           = "${local.possessive_prefix} Artifacts"
  }
}

resource "local_file" "catalog_page_config" {
  content  = jsonencode(local.catalog_page_titles)
  filename = "${path.module}/.terraform/catalog-pages-${var.namespace}.json"
}

resource "null_resource" "catalog_page_permissions" {
  count = local.is_subspace ? 0 : 1
  triggers = {
    catalog_pages    = local_file.catalog_page_config.content_md5
    permissions_json = local.page_permissions_json
    script_path      = "${path.module}/scripts/manage-catalog-page-permissions.sh"
    config_file      = local_file.catalog_page_config.filename
    client_id        = var.port_client_id
    client_secret    = var.port_secret
  }

  provisioner "local-exec" {
    command = "${self.triggers.script_path} ${self.triggers.config_file} ${self.triggers.client_id} ${self.triggers.client_secret} '${self.triggers.permissions_json}'"
  }

  depends_on = [port_blueprint_permissions.scoped]
}

resource "port_blueprint_permissions" "scoped" {
  for_each             = local.is_subspace ? {} : local.managed_blueprints
  blueprint_identifier = each.value

  entities = {
    register   = local.team_permission
    unregister = local.team_permission
    update     = local.team_permission
    update_metadata_properties = {
      icon       = local.team_permission
      identifier = local.team_permission
      team = {
        roles         = ["Admin"]
        users         = []
        teams         = []
        owned_by_team = false
      }
      title = local.team_permission
    }
  }

  lifecycle {
    # Port.io auto-populates update_properties and update_relations with per-property
    # moderator-role defaults after every write. We don't manage per-property permissions,
    # so ignore the drift rather than fighting it on every apply.
    ignore_changes = [entities.update_properties, entities.update_relations]
  }
}
