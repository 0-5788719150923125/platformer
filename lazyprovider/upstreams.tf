# Upstreams: the real providers behind the proxies built from this directory
# (platformer.local/lazyprovider/<cloud>; see README.md). This directory is also a
# Terraform module with no resources, called from the root's main.tf, so
# `terraform init` installs and verifies these while nothing uses or sets them up
# directly; each proxy starts its real provider from .terraform/providers.
# Terraform reads only the .tf files here and Go only the .go files. (Declaring
# them in the root, next to a provider block for the proxy, triggers Terraform's
# "Duplicate required provider" warning.)

terraform {
  required_providers {
    aws-upstream = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    oci-upstream = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
    port-upstream = {
      source  = "port-labs/port-labs"
      version = "~> 2.0"
    }
  }
}
