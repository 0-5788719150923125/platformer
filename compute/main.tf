# Compute Module
#
# Compute is a service: classes in, instances and clusters out. This layer is
# generic; the implementations are adapters:
#
#   compute/aws/  - AWS, the reference implementation (ec2, eks and ecs classes).
#                   AWS is always on, so it's called directly below. Until its
#                   settings move under an `aws:` key, it takes exactly the same
#                   inputs as this module (aws/variables.tf links to ours).
#   compute/oci/  - Oracle Cloud (type = "instance", cloud = "oci"), wired in per
#                   workspace by scripts/providers.sh (see adapters.tf).
#   localhost.tf  - runs applications on the machine running Terraform.
#
# Resources that lived here before the split are moved by moved.tf.

locals {
  # All tenants entitled to any class (used by the generic instance expansion)
  effective_tenants = sort(distinct(flatten(values(var.tenants_by_class))))
}

module "aws" {
  source = "./aws"

  namespace                     = var.namespace
  aws_account_id                = var.aws_account_id
  aws_profile                   = var.aws_profile
  valid_tenants                 = var.valid_tenants
  networks                      = var.networks
  tenants_by_class              = var.tenants_by_class
  config                        = var.config
  instance_parameters           = var.instance_parameters
  application_requests          = var.application_requests
  pod_identity_requests         = var.pod_identity_requests
  lb_requests                   = var.lb_requests
  built_amis                    = var.built_amis
  standalone_applications       = var.standalone_applications
  patch_groups_by_class         = var.patch_groups_by_class
  domain_enabled                = var.domain_enabled
  domain_zone_id                = var.domain_zone_id
  domain_zone_name              = var.domain_zone_name
  domain_certificate_arn        = var.domain_certificate_arn
  domain_aliases                = var.domain_aliases
  access_iam_role_arns          = var.access_iam_role_arns
  access_iam_role_names         = var.access_iam_role_names
  access_instance_profile_names = var.access_instance_profile_names
  preflight_enabled             = var.preflight_enabled
}
