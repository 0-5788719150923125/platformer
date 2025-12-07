# Storage Catalog
# Catalogs all storage resources managed by the storage module (S3, RDS, ElastiCache,
# CodeCommit) via dependency inversion. Populated from storage.inventory output.

resource "port_blueprint" "storage" {
  count = local.is_subspace ? 0 : 1

  identifier  = "storage-${var.namespace}"
  title       = "Storage"
  icon        = "Database"
  description = "Storage resources managed by the storage module"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      storageType = {
        title       = "Type"
        description = "Storage resource category"
        required    = true
        enum        = ["s3", "rds-aurora", "rds-standalone", "elasticache-valkey", "elasticache-redis", "elasticache-memcached", "codecommit"]
        enum_colors = {
          s3                    = "blue"
          rds-aurora            = "green"
          rds-standalone        = "turquoise"
          elasticache-valkey    = "orange"
          elasticache-redis     = "red"
          elasticache-memcached = "purple"
          codecommit            = "bronze"
        }
      }
      name = {
        title       = "Resource Name"
        description = "Actual AWS resource name"
        required    = true
      }
      engine = {
        title       = "Engine"
        description = "Database or cache engine"
      }
      description = {
        title       = "Description"
        description = "Purpose of this storage resource"
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
      workspace = {
        title       = "Workspace"
        description = "Terraform workspace that owns this resource"
        required    = true
      }
      url = {
        title       = "Console"
        description = "AWS console link for this resource"
        format      = "url"
      }
      purpose = {
        title       = "Purpose"
        description = "Logical key used in Terraform state (used by self-service actions)"
        required    = true
      }
      resourceAddress = {
        title       = "Resource Address"
        description = "Terraform resource address for self-service taint actions"
      }
    }
  }
}

resource "port_entity" "storage" {
  for_each = {
    for s in var.storage_requests : "${s.storage_type}-${s.purpose}" => s
  }

  identifier = "${each.value.storage_type}-${each.value.purpose}-${var.namespace}"
  title      = each.value.name
  blueprint  = local.bp_storage
  teams      = var.teams

  properties = {
    string_props = {
      storageType     = each.value.storage_type
      name            = each.value.name
      engine          = each.value.engine
      description     = each.value.description
      namespace       = var.subspace
      workspace       = var.namespace
      purpose         = each.value.purpose
      resourceAddress = each.value.resource_address
      url             = each.value.url != null && each.value.url != "" ? "${local.sso_prefix}${urlencode(each.value.url)}" : null
    }
  }

  depends_on = [port_blueprint.storage]
}
