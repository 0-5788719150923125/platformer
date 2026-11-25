# Access Module
#
# access is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   access/aws/ - AWS, the only implementation so far. Until its settings
#                 move under an `aws:` key it takes exactly the same inputs
#                 as this module (aws/variables.tf links to ours).
#
# The AWS adapter is called below. Its provider is platformer/aws (lazyprovider/),
# which only sets itself up in workspaces that enable AWS. Resources that lived
# here before the split are moved by moved.tf.

module "aws" {
  source = "./aws"

  namespace         = var.namespace
  aws_account_id    = var.aws_account_id
  aws_region        = var.aws_region
  access_requests   = var.access_requests
  iam_roles         = var.iam_roles
  security_groups   = var.security_groups
  resource_policies = var.resource_policies
}
