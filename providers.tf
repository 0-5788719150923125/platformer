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

provider "aws" {
  region  = module.workspaces.aws_region
  profile = module.workspaces.aws_profile

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Project   = "Platformer"
      Owner     = module.workspaces.owner
    }
  }
}

# Secondary provider for accessing production account secrets
# Uses example-platform-prod profile for cross-account resource access
provider "aws" {
  alias   = "prod"
  region  = "us-east-2"
  profile = "example-platform-prod"
}

# Infrastructure account provider for cross-account secret replication
# CrowdStrike credentials and other shared secrets live in example-infrastructure-prod
provider "aws" {
  alias   = "infrastructure"
  region  = "us-east-2"
  profile = "example-infrastructure-prod"
}

# Port.io provider for portal module
# Credentials retrieved from AWS Secrets Manager (only in example-platform-dev account)
# Provider is always configured (Terraform requires this), but only used when portal_enabled=true

# Check prod account ID to gate Port credential fetch
# Uses aws.prod since Port credentials live in example-platform-prod
data "aws_caller_identity" "port_check" {
  provider = aws.prod
}

data "aws_secretsmanager_secret_version" "port_credentials" {
  count     = data.aws_caller_identity.port_check.account_id == "111111111111" ? 1 : 0
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
