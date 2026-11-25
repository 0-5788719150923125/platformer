terraform {
  required_version = "~> 1.8"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    deepmerge = {
      source  = "isometry/deepmerge"
      version = "~> 1.2"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "deepmerge" {}

locals {
  aws_configured = module.workspaces.aws_profile != null
}


# Optional Providers
# Providers beyond the always-on set above live in providers/<name>.tf and are
# wired into the root per workspace by scripts/providers.sh: clouds when the
# workspace sets <cloud>_profile (oci_profile), others when it sets
# <name>_enabled = true (port_enabled). This guard fails the plan when the wired
# set doesn't match what the workspace declares - e.g. after `terraform
# workspace select` without re-running the script.
locals {
  optional_providers = toset([for f in fileset("${path.root}/providers", "*_override.tf") : trimsuffix(f, "_override.tf")])
  linked_providers   = toset([for name in local.optional_providers : name if fileexists("${path.root}/provider_${name}.tf")])
  declared_providers = toset(module.workspaces.optional_providers)

  # Services with no implementation beyond AWS (yet)
  aws_only_services = [for name, enabled in {
    arcbot                     = local.arcbot_enabled
    iopacs                     = local.iopacs_enabled
    iorchestrator              = local.iorchestrator_enabled
    ioshare                    = local.ioshare_enabled
    legacy                     = local.legacy_enabled
    secrets                    = local.secrets_enabled
    domains                    = local.domains_enabled
    "configuration-management" = local.configuration_management_enabled
  } : name if enabled]
}

output "optional_providers" {
  description = "Optional providers wired into this workspace"
  value       = sort(local.linked_providers)

  precondition {
    condition     = join(",", sort(local.linked_providers)) == join(",", sort(local.declared_providers))
    error_message = "Provider wiring is stale for workspace \"${terraform.workspace}\": it declares [${join(", ", sort(local.declared_providers))}] but [${join(", ", sort(local.linked_providers))}] is wired in. Run scripts/providers.sh."
  }

  precondition {
    condition     = !contains(local.linked_providers, "port") || contains(local.linked_providers, "aws")
    error_message = "Port reads its credentials through AWS (Secrets Manager): set aws_profile in terraform.tfvars.${terraform.workspace} too, and run scripts/providers.sh."
  }

  precondition {
    condition     = contains(local.linked_providers, "aws") || length(local.aws_only_services) == 0
    error_message = "These services only exist on AWS, which isn't wired into workspace \"${terraform.workspace}\": ${join(", ", local.aws_only_services)}. Set aws_profile in terraform.tfvars.${terraform.workspace} and run scripts/providers.sh."
  }

  precondition {
    condition     = !local.portal_enabled || contains(local.linked_providers, "port")
    error_message = "services.portal needs the Port provider: set port_enabled = true in terraform.tfvars.${terraform.workspace} and run scripts/providers.sh."
  }
}
