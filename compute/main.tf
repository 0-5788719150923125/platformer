# Compute Module
#
# Compute is a service: classes in, instances and clusters out. This layer is
# generic; the implementations are adapters:
#
#   compute/aws/  - AWS, the reference implementation (ec2, eks and ecs classes).
#                   Wired in per workspace when it sets aws_profile. Until its
#                   settings move under an `aws:` key, it takes exactly the same
#                   inputs as this module (aws/variables.tf links to ours).
#   compute/oci/  - Oracle Cloud (type = "instance", cloud = "oci"), wired in per
#                   workspace by scripts/providers.sh (see adapters.tf).
#   localhost.tf  - runs applications on the machine running Terraform.
#
# The AWS adapter is wired in per workspace (aws/wiring.tf.tmpl, linked by
# scripts/providers.sh when the workspace sets aws_profile); its moved blocks travel with it.

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
