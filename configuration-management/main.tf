# Configuration Management Module
#
# configuration-management is a service with cloud adapters (see next/fully-connected.md). This
# layer is generic; the implementation lives in an adapter:
#
#   configuration-management/aws/ - AWS, the only implementation so far. Until its settings
#                                   move under an `aws:` key it takes exactly the same inputs
#                                   as this module (aws/variables.tf links to ours).
#
# The AWS adapter is called below. Its provider is platformer/aws (lazyprovider/),
# which only sets itself up in workspaces that enable AWS. Resources that lived
# here before the split are moved by moved.tf.

module "aws" {
  source = "./aws"

  namespace                       = var.namespace
  redeploy_triggers               = var.redeploy_triggers
  reboot_triggers                 = var.reboot_triggers
  aws_account_id                  = var.aws_account_id
  aws_profile                     = var.aws_profile
  aws_region                      = var.aws_region
  config                          = var.config
  ssm_association_log_bucket      = var.ssm_association_log_bucket
  hooks_bucket                    = var.hooks_bucket
  instances_by_class              = var.instances_by_class
  application_requests            = var.application_requests
  has_application_deployments     = var.has_application_deployments
  application_scripts_bucket      = var.application_scripts_bucket
  instances_role_name             = var.instances_role_name
  instances_role_arn              = var.instances_role_arn
  lambda_requests                 = var.lambda_requests
  event_bus_webhooks              = var.event_bus_webhooks
  aws_sso_start_url               = var.aws_sso_start_url
  ansible_applications_configured = var.ansible_applications_configured
  access_iam_role_arns            = var.access_iam_role_arns
  access_iam_role_names           = var.access_iam_role_names
}
