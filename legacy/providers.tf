terraform {
  required_providers {
    aws = {
      source                = "platformer/aws"
      configuration_aliases = [aws.prod]
    }
  }
}
