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
    port = {
      source  = "port-labs/port-labs"
      version = "~> 2.0"
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

  default_tags {
    tags = local.aws_configured ? {
      ManagedBy = "Terraform"
      Project   = "Platformer"
      Owner     = module.workspaces.owner
    } : {}
  }
}

provider "aws" {
  alias   = "prod"
  profile = try(var.cross_account_providers["prod"].profile, null)
  region  = try(var.cross_account_providers["prod"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "prod")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "prod")
}

provider "aws" {
  alias   = "infrastructure"
  profile = try(var.cross_account_providers["infrastructure"].profile, null)
  region  = try(var.cross_account_providers["infrastructure"].region, "us-east-2")
  skip_credentials_validation = !contains(keys(var.cross_account_providers), "infrastructure")
  skip_requesting_account_id  = !contains(keys(var.cross_account_providers), "infrastructure")
}

locals {
  prod_provider_configured = contains(keys(var.cross_account_providers), "prod")
}

# Port.io provider for portal module
# Credentials retrieved from AWS Secrets Manager (only in example-platform-dev account)
# Provider is always configured (Terraform requires this), but only used when portal_enabled=true

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
