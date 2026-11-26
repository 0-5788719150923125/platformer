terraform {
  required_providers {
    aws = {
      source                = "platformer.local/lazyprovider/aws"
      configuration_aliases = [aws.prod]
    }
  }
}
