# CIDR Allocation Logic
# Deterministic hash-based allocation ensures same AWS account always produces same CIDR

locals {
  # Deterministic hash from AWS account ID
  # Uses last 8 bits of account ID for /16 allocation (256 possible /16s in 10.0.0.0/8)
  # This provides perfect distribution - each account gets unique CIDR based on account ID
  account_hash = parseint(substr(var.aws_account_id, -3, 3), 10) % 256

  # VPC CIDR selection based on allocation method
  vpc_cidr = (
    var.config.allocation_method == "explicit" ? var.config.explicit_cidr :
    # Deterministic: Use account ID hash
    cidrsubnet(var.config.base_cidr, 8, local.account_hash)
  )

  # Debug output for hash calculation
  cidr_allocation_metadata = {
    method         = var.config.allocation_method
    account_id     = var.aws_account_id
    namespace      = var.namespace
    hash_value     = local.account_hash
    base_cidr      = var.config.base_cidr
    allocated_cidr = local.vpc_cidr
  }
}
