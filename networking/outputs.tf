# Networking Module Outputs
# These outputs provide the interface for compute and other modules via dependency inversion

# VPC information
output "vpc" {
  description = "VPC metadata"
  value = var.config.allocation_method == "default" ? {
    id         = data.aws_vpc.default[0].id
    arn        = data.aws_vpc.default[0].arn
    cidr_block = data.aws_vpc.default[0].cidr_block
    region     = data.aws_region.current.id
    } : {
    id         = aws_vpc.network[0].id
    arn        = aws_vpc.network[0].arn
    cidr_block = aws_vpc.network[0].cidr_block
    region     = data.aws_region.current.id
  }
}

# Subnet inventory grouped by tier
output "subnets_by_tier" {
  description = "Subnets grouped by tier (private/public/intra) with all subnet IDs and CIDRs"
  value = var.config.allocation_method == "default" ? {
    # Default VPC: all subnets go in "public" tier (default VPC subnets are public)
    public = {
      ids         = data.aws_subnets.default[0].ids
      cidr_blocks = [] # Not easily available from data source
      by_az       = {} # Not easily available from data source
    }
    # Also provide as "private" for EKS compatibility (will use public subnets)
    private = {
      ids         = data.aws_subnets.default[0].ids
      cidr_blocks = []
      by_az       = {}
    }
    } : {
    for tier_name in keys(var.config.subnet_topology) :
    tier_name => {
      # All subnet IDs in this tier (across all AZs)
      ids = [
        for subnet_key, subnet_config in local.subnets :
        aws_subnet.subnets[subnet_key].id
        if subnet_config.tier == tier_name
      ]
      # All subnet CIDRs in this tier
      cidr_blocks = [
        for subnet_key, subnet_config in local.subnets :
        subnet_config.cidr_block
        if subnet_config.tier == tier_name
      ]
      # Subnets organized by AZ within this tier
      by_az = {
        for az_name in local.selected_azs :
        az_name => {
          ids = [
            for subnet_key, subnet_config in local.subnets :
            aws_subnet.subnets[subnet_key].id
            if subnet_config.tier == tier_name && subnet_config.az == az_name
          ]
          cidr_blocks = [
            for subnet_key, subnet_config in local.subnets :
            subnet_config.cidr_block
            if subnet_config.tier == tier_name && subnet_config.az == az_name
          ]
        }
      }
    }
  }
}

# Complete subnet inventory (all tiers, all AZs)
output "all_subnets" {
  description = "Complete subnet inventory with metadata"
  value = var.config.allocation_method == "default" ? {} : {
    for subnet_key, subnet_config in local.subnets :
    subnet_key => {
      id         = aws_subnet.subnets[subnet_key].id
      arn        = aws_subnet.subnets[subnet_key].arn
      cidr_block = subnet_config.cidr_block
      az         = subnet_config.az
      tier       = subnet_config.tier
    }
  }
}

# NAT Gateway information (for allowlisting egress IPs)
output "nat_gateways" {
  description = "NAT Gateway Elastic IPs for egress traffic allowlisting"
  value = var.config.allocation_method == "default" ? {} : {
    for az_name, nat_gw in aws_nat_gateway.main :
    az_name => {
      id                   = nat_gw.id
      public_ip            = aws_eip.nat[az_name].public_ip
      allocation_id        = aws_eip.nat[az_name].allocation_id
      network_interface_id = nat_gw.network_interface_id
    }
  }
}

# Internet Gateway information
output "internet_gateway" {
  description = "Internet Gateway metadata"
  value = var.config.allocation_method == "default" ? null : (
    local.has_public_subnets ? {
      id  = aws_internet_gateway.main[0].id
      arn = aws_internet_gateway.main[0].arn
    } : null
  )
}

# Route table information
output "route_tables" {
  description = "Route table IDs by type"
  value = var.config.allocation_method == "default" ? {
    public  = null
    private = {}
    intra   = null
    } : {
    public = local.has_public_subnets ? {
      id  = aws_route_table.public[0].id
      arn = aws_route_table.public[0].arn
    } : null

    private = {
      for az_name, rt in aws_route_table.private :
      az_name => {
        id  = rt.id
        arn = rt.arn
      }
    }

    intra = local.has_intra_subnets ? {
      id  = aws_route_table.intra[0].id
      arn = aws_route_table.intra[0].arn
    } : null
  }
}

# CIDR allocation metadata (for debugging and validation)
output "cidr_allocation" {
  description = "CIDR allocation metadata"
  value = var.config.allocation_method == "default" ? {
    method         = "default"
    allocated_cidr = data.aws_vpc.default[0].cidr_block
  } : local.cidr_allocation_metadata
}

# Availability zone metadata
output "availability_zones" {
  description = "Availability zone selection metadata"
  value = var.config.allocation_method == "default" ? {
    available_azs    = []
    selected_azs     = []
    az_count         = 0
    selection_method = "default"
  } : local.az_metadata
}

# Network configuration summary
output "network_summary" {
  description = "High-level network configuration summary"
  value = var.config.allocation_method == "default" ? {
    vpc_id       = data.aws_vpc.default[0].id
    vpc_cidr     = data.aws_vpc.default[0].cidr_block
    region       = data.aws_region.current.id
    az_count     = length(data.aws_subnets.default[0].ids)
    azs          = []
    subnet_tiers = ["public", "private"]
    subnet_count = length(data.aws_subnets.default[0].ids)
    has_nat      = false
    has_igw      = true
    namespace    = var.namespace
    account_id   = var.aws_account_id
    } : {
    vpc_id       = aws_vpc.network[0].id
    vpc_cidr     = local.vpc_cidr
    region       = data.aws_region.current.id
    az_count     = length(local.selected_azs)
    azs          = local.selected_azs
    subnet_tiers = keys(var.config.subnet_topology)
    subnet_count = length(local.subnets)
    has_nat      = length(local.nat_gateway_azs) > 0
    has_igw      = local.has_public_subnets
    namespace    = var.namespace
    account_id   = var.aws_account_id
  }
}
