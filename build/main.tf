# Build Module
#
# build is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   build/aws/ - AWS, the only implementation so far. Until its settings
#                move under an `aws:` key it takes exactly the same inputs
#                as this module (aws/variables.tf links to ours).
#
# The AWS adapter is called below. Its provider is platformer/aws (lazyprovider/),
# which only sets itself up in workspaces that enable AWS. Resources that lived
# here before the split are moved by moved.tf.

module "aws" {
  source = "./aws"

  namespace                     = var.namespace
  aws_profile                   = var.aws_profile
  config                        = var.config
  standalone_applications       = var.standalone_applications
  vpc_id                        = var.vpc_id
  subnet_id                     = var.subnet_id
  application_scripts_bucket    = var.application_scripts_bucket
  access_iam_role_names         = var.access_iam_role_names
  access_instance_profile_names = var.access_instance_profile_names
}
