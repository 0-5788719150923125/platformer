# Storage Module
#
# storage is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   storage/aws/ - AWS, the only implementation so far. Until its settings
#                  move under an `aws:` key it takes exactly the same inputs
#                  as this module (aws/variables.tf links to ours).
#
# The AWS adapter is called below. Its provider is platformer/aws (lazyprovider/),
# which only sets itself up in workspaces that enable AWS. Resources that lived
# here before the split are moved by moved.tf.

module "aws" {
  source = "./aws"

  namespace                    = var.namespace
  aws_account_id               = var.aws_account_id
  bucket_requests              = var.bucket_requests
  rds_cluster_requests         = var.rds_cluster_requests
  elasticache_cluster_requests = var.elasticache_cluster_requests
  volume_requests              = var.volume_requests
  repository_requests          = var.repository_requests
  aws_profile                  = var.aws_profile
  aws_region                   = var.aws_region
}
