# Secrets Module
#
# secrets is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   secrets/aws/ - AWS, the only implementation so far. Until its settings
#                  move under an `aws:` key it takes exactly the same inputs
#                  as this module (aws/variables.tf links to ours).
#
# The AWS adapter is called below. Its provider is platformer/aws (lazyprovider/),
# which only sets itself up in workspaces that enable AWS. Resources that lived
# here before the split are moved by moved.tf.

terraform {
  required_providers {
    aws = {
      source                = "platformer/aws"
      configuration_aliases = [aws.infrastructure, aws.prod]
    }
  }
}

module "aws" {
  source = "./aws"

  providers = {
    aws                = aws
    aws.infrastructure = aws.infrastructure
    aws.prod           = aws.prod
  }

  namespace      = var.namespace
  aws_account_id = var.aws_account_id
  config         = var.config
}
