# Data source to get current AWS region
data "aws_region" "current" {}

# Data source to get current AWS account information
data "aws_caller_identity" "current" {}

# AMI discovery per EC2 class - two strategies:
#
# 1. SSM Parameter (preferred): Reads the canonical "latest AMI" pointer that AWS
#    maintains in Parameter Store. Deterministic - always returns a single AMI ID.
#    Example: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
#
# 2. AMI Filter (fallback): Searches for AMIs matching a name pattern and picks
#    the most recent by creation_date. Non-deterministic when the filter matches
#    multiple AMI families (e.g., kernel-* spans kernel-6.1, kernel-6.6, kernel-6.12).

# Strategy 1: SSM parameter lookup - only for classes that specify ami_ssm_parameter
data "aws_ssm_parameter" "ami" {
  for_each = {
    for class_name, class_config in local.ec2_classes : class_name => class_config
    if class_config.ami_ssm_parameter != null
  }

  name = each.value.ami_ssm_parameter
}

# Strategy 2: AMI filter - only for classes that use ami_filter (without ami_ssm_parameter)
data "aws_ami" "class" {
  for_each = {
    for class_name, class_config in local.ec2_classes : class_name => class_config
    if class_config.ami_ssm_parameter == null && class_config.ami_filter != null
  }

  most_recent = true
  owners      = [coalesce(each.value.ami_owner, "amazon")]

  filter {
    name   = "name"
    values = [each.value.ami_filter]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Unified AMI ID map - SSM parameter wins when both are specified
locals {
  resolved_amis = merge(
    { for k, v in data.aws_ami.class : k => v.id },
    { for k, v in data.aws_ssm_parameter.ami : k => nonsensitive(v.value) },
  )
}

# SSO Role Discovery for EKS Access (only when EKS clusters exist)
# Discovers the organization-cloud-admin SSO role ARN dynamically per account
# The role suffix (random string) varies by account, so we query IAM to find it
data "aws_iam_roles" "sso_roles" {
  count = length(local.eks_classes) > 0 ? 1 : 0

  # Filter by IAM path - all SSO roles are under /aws-reserved/sso.amazonaws.com/
  path_prefix = "/aws-reserved/sso.amazonaws.com/"

  # Filter by name prefix - matches AWSReservedSSO_organization-cloud-admin*
  name_regex = "^AWSReservedSSO_organization-cloud-admin"
}
