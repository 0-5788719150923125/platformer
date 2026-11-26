# Compute Module
#
# Compute is a service: classes in, instances and clusters out. This layer is
# generic; the implementations are adapters:
#
#   compute/aws/  - AWS, the reference implementation (ec2, eks and ecs classes).
#                   Called directly below; AWS is set up only where enabled. Until its
#                   settings move under an `aws:` key, it takes exactly the same
#                   inputs as this module (aws/variables.tf links to ours).
#   compute/oci/  - Oracle Cloud (type = "instance", cloud = "oci"), wired in per
#                   called from adapters.tf; set up only where OCI is enabled.
#   localhost.tf  - runs applications on the machine running Terraform.
#
# The AWS adapter is called below. Its provider is
# platformer.local/lazyprovider/aws (lazyprovider/), which only sets itself up in
# workspaces that enable AWS. Resources that lived here before the split are moved
# by moved.tf.

locals {
  # All tenants entitled to any class (used by the generic instance expansion)
  effective_tenants = sort(distinct(flatten(values(var.tenants_by_class))))
}

# Generic instances on AWS (type = "instance", cloud = "aws") run on the AWS
# adapter's EC2 path: their aws: settings are lifted to where that path reads
# them, and the class becomes type = "ec2". Instance keys, resources and state
# are the same either way.
locals {
  aws_config = {
    for class_name, class_config in var.config : class_name => (
      class_config.type == "instance" && class_config.cloud == "aws"
      ? merge(class_config, { for field, value in class_config.aws : field => value if value != null }, { type = "ec2" })
      : class_config
    )
  }
}

module "aws" {
  source = "./aws"

  namespace                     = var.namespace
  aws_account_id                = var.aws_account_id
  aws_profile                   = var.aws_profile
  valid_tenants                 = var.valid_tenants
  networks                      = var.networks
  tenants_by_class              = var.tenants_by_class
  config                        = local.aws_config
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
