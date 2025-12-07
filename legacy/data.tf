# Current region
data "aws_region" "current" {}

# Current AWS account ID (for AMI ownership)
data "aws_caller_identity" "current" {}

# Find the Atlantis AMI built by Packer
# This depends on the packer build completing first
data "aws_ami" "atlantis" {
  depends_on = [null_resource.build_atlantis_ami]

  most_recent = true
  owners      = [data.aws_caller_identity.current.account_id]

  filter {
    name   = "name"
    values = ["atlantis-legacy-${var.namespace}-*"]
  }

  filter {
    name   = "tag:Namespace"
    values = [var.namespace]
  }

  filter {
    name   = "tag:Service"
    values = ["atlantis"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Default VPC
data "aws_vpc" "default" {
  default = true
}

# Select a proper default subnet (one that has MapPublicIpOnLaunch=true)
data "aws_subnet" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }

  # Pick any availability zone - they all work
  availability_zone = "us-east-2a"
}
