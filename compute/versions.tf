# Clouds go through Platformer's lazy proxies (lazyprovider/): never set up
# in workspaces that don't enable them.
terraform {
  required_providers {
    aws = {
      source = "platformer.local/lazyprovider/aws"
    }
    oci = {
      source = "platformer.local/lazyprovider/oci"
    }
  }
}
