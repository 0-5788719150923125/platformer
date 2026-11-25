# Networking Module
#
# networking is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   networking/aws/ - AWS, the only implementation so far. Until its settings
#                     move under an `aws:` key it takes exactly the same inputs
#                     as this module (aws/variables.tf links to ours).
#
# The AWS adapter is called below. Its provider is platformer/aws (lazyprovider/),
# which only sets itself up in workspaces that enable AWS. Resources that lived
# here before the split are moved by moved.tf.

module "aws" {
  source = "./aws"

  namespace      = var.namespace
  aws_account_id = var.aws_account_id
  network_name   = var.network_name
  config         = var.config
}
