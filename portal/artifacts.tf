# Artifact Registry
# Catalogs build artifacts produced by platformer modules (archives, docker images,
# helm charts, golden images, etc.) via dependency inversion.
# Populated by any module that emits artifact_requests - currently: archivist.

resource "port_blueprint" "artifact" {
  count = local.is_subspace ? 0 : 1

  identifier  = "artifact-${var.namespace}"
  title       = "Artifacts"
  icon        = "Package"
  description = "Build artifacts produced by platformer modules"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      artifactType = {
        title       = "Type"
        description = "Artifact category"
        required    = true
        enum        = ["archive", "docker-image", "helm-chart", "golden-image", "git-repository"]
        enum_colors = {
          archive        = "blue"
          docker-image   = "turquoise"
          helm-chart     = "green"
          golden-image   = "orange"
          git-repository = "purple"
        }
      }
      version = {
        title       = "Version"
        description = "Version tag or git SHA"
        required    = true
      }
      path = {
        title       = "Path"
        description = "Local filesystem path or remote URL"
      }
      source = {
        title       = "Source"
        description = "Module that produced this artifact"
        required    = true
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
      createdAt = {
        title       = "Created"
        description = "When this artifact was built"
        format      = "date-time"
      }
      url = {
        title       = "Download"
        description = "Console link to view or download this artifact"
        format      = "url"
      }
      workspace = {
        title       = "Workspace"
        description = "Terraform workspace that produced this artifact"
        required    = true
      }
    }
  }
}

resource "port_entity" "artifact" {
  for_each = {
    for a in var.artifact_requests :
    "${a.source}-${a.name}-${a.type}-${a.version}" => a
  }

  identifier = "${each.key}-${var.namespace}"
  title      = "${each.value.name}@${each.value.version}"
  blueprint  = local.bp_artifact
  teams      = var.teams

  properties = {
    string_props = {
      artifactType = each.value.type
      version      = each.value.version
      path         = each.value.path
      source       = each.value.source
      namespace    = var.subspace
      workspace    = var.namespace
      createdAt    = each.value.created_at
      url          = each.value.url != null && each.value.url != "" ? "${local.sso_prefix}${urlencode(each.value.url)}" : null
    }
  }

  depends_on = [port_blueprint.artifact]
}
