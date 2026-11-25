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
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "deepmerge" {}

locals {
  aws_configured = module.workspaces.aws_profile != null
}

provider "aws" {
  region  = module.workspaces.aws_region
  profile = module.workspaces.aws_profile

  skip_credentials_validation = !local.aws_configured
  skip_requesting_account_id  = !local.aws_configured

  # Without an AWS profile (aws_profile = null) the provider still gets set up,
  # because modules mention it even when count = 0, and it insists on finding
  # credentials somewhere. Placeholder keys satisfy that without ever reaching
  # AWS. The aliases below get them only when AWS isn't configured at all, so
  # with AWS they keep falling back to the default credentials as before.
  # Interim measure until AWS is wired in per workspace like providers/oci.tf.
  access_key              = local.aws_configured ? null : "unconfigured"
  secret_key              = local.aws_configured ? null : "unconfigured"
  skip_metadata_api_check = !local.aws_configured

  default_tags {
    tags = local.aws_configured ? {
      ManagedBy = "Terraform"
      Project   = "Platformer"
      Owner     = module.workspaces.owner
    } : {}
  }
}

provider "aws" {
  alias                       = "prod"
  profile                     = try(var.cross_account_providers["prod"].profile, null)
  region                      = try(var.cross_account_providers["prod"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "prod")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "prod")
  access_key                  = local.aws_configured || contains(keys(var.cross_account_providers), "prod") ? null : "unconfigured"
  secret_key                  = local.aws_configured || contains(keys(var.cross_account_providers), "prod") ? null : "unconfigured"
  skip_metadata_api_check     = !local.aws_configured && !contains(keys(var.cross_account_providers), "prod")
}

provider "aws" {
  alias                       = "infrastructure"
  profile                     = try(var.cross_account_providers["infrastructure"].profile, null)
  region                      = try(var.cross_account_providers["infrastructure"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "infrastructure")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "infrastructure")
  access_key                  = local.aws_configured || contains(keys(var.cross_account_providers), "infrastructure") ? null : "unconfigured"
  secret_key                  = local.aws_configured || contains(keys(var.cross_account_providers), "infrastructure") ? null : "unconfigured"
  skip_metadata_api_check     = !local.aws_configured && !contains(keys(var.cross_account_providers), "infrastructure")
}

locals {
  prod_provider_configured = contains(keys(var.cross_account_providers), "prod")
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
}

output "optional_providers" {
  description = "Optional providers wired into this workspace"
  value       = sort(local.linked_providers)

  precondition {
    condition     = join(",", sort(local.linked_providers)) == join(",", sort(local.declared_providers))
    error_message = "Provider wiring is stale for workspace \"${terraform.workspace}\": it declares [${join(", ", sort(local.declared_providers))}] but [${join(", ", sort(local.linked_providers))}] is wired in. Run scripts/providers.sh."
  }

  precondition {
    condition     = !local.portal_enabled || contains(local.linked_providers, "port")
    error_message = "services.portal needs the Port provider: set port_enabled = true in terraform.tfvars.${terraform.workspace} and run scripts/providers.sh."
  }
}
