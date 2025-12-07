# Data source to get current AWS region
data "aws_region" "current" {}

# Data source to get current AWS account information
data "aws_caller_identity" "current" {}

# Default VPC discovery (when allocation_method = "default")
data "aws_vpc" "default" {
  count   = var.config.allocation_method == "default" ? 1 : 0
  default = true
}

# Default VPC subnets (when allocation_method = "default")
data "aws_subnets" "default" {
  count = var.config.allocation_method == "default" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Discover available availability zones
data "aws_availability_zones" "available" {
  state = "available"

  # Filter out local zones (only use standard AZs)
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Select AZs based on configuration strategy
  selected_azs = (
    var.config.az_selection == "explicit" ? var.config.explicit_azs :
    var.config.az_selection == "all" ? slice(data.aws_availability_zones.available.names, 0, min(length(data.aws_availability_zones.available.names), var.config.max_azs)) :
    # Default: alphabetical - first N AZs sorted alphabetically (deterministic)
    slice(sort(data.aws_availability_zones.available.names), 0, min(var.config.az_count, length(data.aws_availability_zones.available.names)))
  )

  # AZ metadata for debugging
  az_metadata = {
    available_azs    = data.aws_availability_zones.available.names
    selected_azs     = local.selected_azs
    az_count         = length(local.selected_azs)
    selection_method = var.config.az_selection
  }
}
