terraform {
  required_providers {
    aws = {
      source = "platformer.local/lazyprovider/aws"
    }
    port = {
      source = "platformer.local/lazyprovider/port"
    }
  }
}
