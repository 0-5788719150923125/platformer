# Port.io Blueprint Definitions
# Blueprints define the schema for entities in the Port catalog

# Documentation Blueprint
# Stores markdown documentation from platformer/next/* with metadata
resource "port_blueprint" "documentation" {
  count = local.is_subspace ? 0 : 1

  identifier  = "documentation-${var.namespace}"
  title       = "Documentation"
  icon        = "FileText"
  description = "Platformer framework documentation and design principles"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      content = {
        title       = "Content"
        type        = "string"
        format      = "markdown"
        description = "Full markdown content"
      }
      category = {
        title       = "Category"
        type        = "string"
        description = "Document category based on source"
        enum = [
          "behind",
          "learning",
          "module",
          "near",
          "next",
          "presentation",
          "spec"
        ]
        enum_colors = {
          behind       = "darkGray"
          learning     = "orange"
          module       = "green"
          near         = "turquoise"
          next         = "blue"
          presentation = "pink"
          spec         = "purple"
        }
      }
      summary = {
        title       = "Summary"
        description = "Brief summary of document content"
      }
      filename = {
        title       = "Filename"
        description = "Original filename"
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
      }
      status = {
        title = "Status"
        type  = "string"
        enum  = ["Draft", "Published", "Archived"]
        enum_colors = {
          Draft     = "yellow"
          Published = "green"
          Archived  = "darkGray"
        }
        default = "Published"
      }
    }
    array_props = {
      tags = {
        title       = "Tags"
        description = "Searchable tags for categorization"
      }
    }
  }
}

# Git Commit Blueprint
# Stores recent git commits for the platformer repository
resource "port_blueprint" "git_commit" {
  count = local.is_subspace ? 0 : 1

  identifier  = "gitCommit-${var.namespace}"
  title       = "Git Commit"
  icon        = "Git"
  description = "Recent git commits for platformer repository"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      hash = {
        title       = "Hash"
        description = "Short commit hash"
        required    = true
      }
      fullTitle = {
        title       = "Full Title"
        description = "Complete commit message title"
      }
      title = {
        title       = "Title"
        description = "Commit message with key prefix removed"
        required    = true
      }
      key = {
        title       = "Key"
        description = "Jira/ticket key extracted from commit (e.g., PROJ-5103)"
      }
      author = {
        title       = "Author"
        description = "Commit author name"
        required    = true
      }
      absoluteTimestamp = {
        title       = "Time"
        description = "ISO 8601 commit timestamp"
        format      = "date-time"
        required    = true
      }
      commitUrl = {
        title       = "Commit URL"
        description = "GitHub URL to view this commit"
        format      = "url"
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
    }
  }
}

# Tenant Entitlements Blueprint
# Stores tenant codes and their service entitlements
resource "port_blueprint" "tenant_entitlement" {
  count = local.is_subspace ? 0 : 1

  identifier  = "tenantEntitlement-${var.namespace}"
  title       = "Tenant Entitlement"
  icon        = "Users"
  description = "Tenant service entitlements and access control"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      tenantCode = {
        title       = "Tenant Code"
        description = "Unique tenant identifier"
        required    = true
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
    }
    array_props = {
      entitlements = {
        title       = "Entitlements"
        description = "List of service entitlements (e.g., compute.*, archshare.*)"
      }
    }
  }
}

# Service URL Blueprint
# Unified registry of service URLs across all modules with tenant mapping
resource "port_blueprint" "service_url" {
  count = local.is_subspace ? 0 : 1

  identifier  = "serviceUrl-${var.namespace}"
  title       = "Service URL"
  icon        = "Link"
  description = "Service access URLs with tenant and deployment mapping"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      url = {
        title       = "URL"
        description = "Service access URL (null for command-based lazy evaluation)"
        format      = "url"
      }
      urlLabel = {
        title       = "Service"
        description = "Human-readable label for the URL"
        required    = true
      }
      tenantList = {
        title       = "Tenants"
        description = "Comma-separated list of tenant codes with access"
        required    = true
      }
      module = {
        title       = "Module"
        description = "Source module (e.g., archorchestrator, archshare, compute)"
        enum = [
          "archbot",
          "archorchestrator",
          "archshare",
          "compute",
          "archpacs",
          "observability"
        ]
        enum_colors = {
          archbot          = "red"
          archorchestrator = "blue"
          archshare        = "green"
          compute          = "orange"
          archpacs         = "purple"
          observability    = "turquoise"
        }
      }
      deployment = {
        title       = "Deployment"
        description = "Deployment name or class identifier"
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
      workspace = {
        title       = "Workspace"
        description = "Terraform workspace that produced this entry"
        required    = true
      }
    }
  }
}

# State Fragment Blueprint
# Catalog of state fragments used in this deployment
resource "port_blueprint" "state_fragment" {
  count = local.is_subspace ? 0 : 1

  identifier  = "stateFragment-${var.namespace}"
  title       = "State"
  icon        = "Code"
  description = "State fragments loaded for this deployment"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      yamlContent = {
        title       = "Content"
        type        = "string"
        format      = "markdown"
        description = "Full YAML content of the state fragment"
      }
      filename = {
        title       = "Filename"
        description = "State fragment filename"
        required    = true
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
      githubUrl = {
        title       = "View on GitHub"
        description = "Link to view this state fragment on GitHub"
        format      = "url"
      }
      enabled = {
        title       = "Enabled"
        description = "Whether this state is actively used in the deployment"
        required    = true
        enum        = ["true", "false"]
        enum_colors = {
          "true"  = "green"
          "false" = "lightGray"
        }
      }
      workspace = {
        title       = "Workspace"
        description = "Terraform workspace that produced this entry"
        required    = true
      }
    }
    array_props = {
      services = {
        title       = "Services"
        description = "Services configured in this state fragment"
      }
    }
  }
}

# Event Bus Blueprint
# Lifecycle events from infrastructure components (CodeBuild, Lambda, ECS, etc.)
resource "port_blueprint" "event_bus" {
  count = local.is_subspace ? 0 : 1

  identifier  = "eventBus-${var.namespace}"
  title       = "Event Bus"
  icon        = "Webhook"
  description = "Infrastructure lifecycle events from various modules"

  force_delete_entities = true

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      eventType = {
        title       = "Event Type"
        description = "Event category"
        required    = true
        enum = [
          "codebuild",
          "lambda",
          "ecs-task",
          "stepfunctions",
          "eventbridge",
          "kb-ingestion"
        ]
        enum_colors = {
          codebuild     = "blue"
          lambda        = "orange"
          ecs-task      = "green"
          stepfunctions = "purple"
          eventbridge   = "turquoise"
          kb-ingestion  = "pink"
        }
      }
      status = {
        title       = "Status"
        description = "Event status"
        required    = true
        enum = [
          "STARTED",
          "IN_PROGRESS",
          "SUCCEEDED",
          "FAILED",
          "STOPPED",
          "TIMED_OUT"
        ]
        enum_colors = {
          STARTED     = "lightGray"
          IN_PROGRESS = "yellow"
          SUCCEEDED   = "green"
          FAILED      = "red"
          STOPPED     = "darkGray"
          TIMED_OUT   = "orange"
        }
      }
      source = {
        title       = "Source"
        description = "Source module that generated the event"
        required    = true
      }
      message = {
        title       = "Message"
        description = "Human-readable event description"
        required    = true
      }
      timestamp = {
        title       = "Timestamp"
        description = "Event timestamp"
        format      = "date-time"
        required    = true
      }
      namespace = {
        title       = "Namespace"
        description = "Deployment namespace for isolation"
        required    = true
      }
      resourceId = {
        title       = "Resource ID"
        description = "AWS resource identifier (build ID, task ARN, etc.)"
      }
      resourceName = {
        title       = "Resource Name"
        description = "Human-readable resource name"
      }
      awsUrl = {
        title       = "AWS Console"
        description = "Link to AWS Console with SSO wrapping"
        format      = "url"
      }
      details = {
        title       = "Details"
        description = "Additional event details in JSON/markdown format"
        format      = "markdown"
      }
      errorMessage = {
        title       = "Error Message"
        description = "Error message for failed events"
      }
      triggeredBy = {
        title       = "Triggered By"
        description = "What triggered the event (user, schedule, webhook, etc.)"
      }
      workspace = {
        title       = "Workspace"
        description = "Terraform workspace that registered this webhook"
        required    = true
      }
    }
    number_props = {
      duration = {
        title       = "Duration"
        description = "Event duration in seconds for completed events"
      }
    }
  }
}
