# Upstreams
#
# The real providers behind Platformer's lazy proxies (platformer/aws,
# platformer/oci, platformer/port; see lazyprovider/). They're declared here,
# in a module with no resources, so `terraform init` installs and verifies them
# while nothing uses or sets them up directly; each proxy starts its real
# provider from .terraform/providers. (Declaring them in the root, next to a
# provider block for the proxy, triggers Terraform's "Duplicate required
# provider" warning.)

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
