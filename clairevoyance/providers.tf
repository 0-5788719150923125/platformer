# Provider requirements for ClaireVoyance module
# The nested hackathon-8 module requires these providers
#
# NOTE: This module is hardcoded to deploy in us-east-1 region only.
# The hackathon-8 repository has hardcoded us-east-1 AZ filters in its
# subnet queries, so it cannot be deployed in other regions.

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }
}
