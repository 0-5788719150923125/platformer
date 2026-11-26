terraform {
  required_providers {
    aws = {
      source = "platformer.local/lazyprovider/aws"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
