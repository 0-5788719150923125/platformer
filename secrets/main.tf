# Secrets Module
#
# secrets is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   secrets/aws/ - AWS, the only implementation so far. Until its settings
#                  move under an `aws:` key it takes exactly the same inputs
#                  as this module (aws/variables.tf links to ours).
#
# The AWS adapter is wired in per workspace (aws/wiring.tf.tmpl, linked by
# scripts/providers.sh when the workspace sets aws_profile); its moved blocks travel with it.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.infrastructure, aws.prod]
    }
  }
}
