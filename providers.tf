terraform {
  required_version = "~> 1.8"

  required_providers {
    # Clouds go through platformer/<cloud>: lazy proxies in front of the real
    # providers (lazyprovider/, built by scripts/build-providers.sh). A provider
    # block with enabled = false is never set up, so a workspace doesn't need
    # credentials for clouds it doesn't use. The real providers are declared in
    # upstreams/.
    aws = {
      source  = "platformer/aws"
      version = "~> 0.1"
    }
    oci = {
      source  = "platformer/oci"
      version = "~> 0.1"
    }
    port = {
      source  = "platformer/port"
      version = "~> 0.1"
    }
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


# Providers a workspace enables: AWS with aws_profile, OCI with oci_profile,
# Port with port_enabled = true (terraform.tfvars.<workspace>). Each one's
# provider block sets `enabled` from this, inside the graph.
locals {
  enabled_providers = toset(module.workspaces.optional_providers)
  oci_enabled       = contains(local.enabled_providers, "oci")
  port_enabled      = contains(local.enabled_providers, "port")

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

output "enabled_providers" {
  description = "Lazy providers enabled in this workspace (the rest are never set up)"
  value       = sort(local.enabled_providers)

  precondition {
    condition     = local.aws_configured || length(local.aws_only_services) == 0
    error_message = "These services only exist on AWS, which workspace \"${terraform.workspace}\" doesn't enable: ${join(", ", local.aws_only_services)}. Set aws_profile in terraform.tfvars.${terraform.workspace}."
  }

  precondition {
    condition     = !local.port_enabled || local.aws_configured
    error_message = "Port reads its credentials through AWS (Secrets Manager): set aws_profile in terraform.tfvars.${terraform.workspace} too."
  }

  precondition {
    condition     = !local.portal_enabled || local.port_enabled
    error_message = "services.portal needs Port: set port_enabled = true in terraform.tfvars.${terraform.workspace}."
  }
}

# AWS

provider "aws" {
  enabled = local.aws_configured # lazyprovider: AWS is never set up where this is false
  region  = module.workspaces.aws_region
  profile = module.workspaces.aws_profile


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
  enabled                     = local.aws_configured || contains(keys(var.cross_account_providers), "prod")
  profile                     = try(var.cross_account_providers["prod"].profile, null)
  region                      = try(var.cross_account_providers["prod"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "prod")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "prod")
}

provider "aws" {
  alias                       = "infrastructure"
  enabled                     = local.aws_configured || contains(keys(var.cross_account_providers), "infrastructure")
  profile                     = try(var.cross_account_providers["infrastructure"].profile, null)
  region                      = try(var.cross_account_providers["infrastructure"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "infrastructure")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "infrastructure")
}

locals {
  prod_provider_configured = contains(keys(var.cross_account_providers), "prod")
}

# Oracle Cloud (OCI)

provider "oci" {
  enabled             = local.oci_enabled
  config_file_profile = module.workspaces.oci_profile
  region              = module.workspaces.oci_region
}

# Port.io (portal backend; access is currently gone, kept for anyone who has it)

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
  enabled   = local.port_enabled
  client_id = local.port_credentials.client_id
  secret    = local.port_credentials.client_secret
  base_url  = "https://api.us.getport.io"
}
