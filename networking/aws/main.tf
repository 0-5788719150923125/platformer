# VPC and Subnet Resources

locals {
  # Skip all custom infrastructure calculations when using default VPC
  using_default_vpc = var.config.allocation_method == "default"

  # Generate subnets: tier × AZ matrix (only for custom VPC)
  # Each subnet gets a unique CIDR calculated from tier offset + AZ index
  subnets = local.using_default_vpc ? {} : merge([
    for tier_name, tier_config in var.config.subnet_topology : {
      for az_idx, az_name in local.selected_azs :
      "${tier_name}-${az_name}" => {
        tier       = tier_name
        az         = az_name
        az_index   = az_idx
        cidr_block = cidrsubnet(local.vpc_cidr, tier_config.cidr_newbits, tier_config.offset + az_idx)
        config     = tier_config
      }
    }
  ]...)

  # Group subnets by tier for easy lookups (only for custom VPC)
  subnets_by_tier = local.using_default_vpc ? {} : {
    for tier_name in keys(var.config.subnet_topology) :
    tier_name => {
      for subnet_key, subnet_config in local.subnets :
      subnet_key => subnet_config
      if subnet_config.tier == tier_name
    }
  }

  # Group subnets by AZ (only for custom VPC)
  subnets_by_az = local.using_default_vpc ? {} : {
    for tier_name in keys(var.config.subnet_topology) :
    tier_name => {
      for az_name in local.selected_azs :
      az_name => [
        for subnet_key, subnet_config in local.subnets :
        subnet_config
        if subnet_config.tier == tier_name && subnet_config.az == az_name
      ]
    }
  }

  # Identify tiers that need specific routing (only for custom VPC)
  has_public_subnets = local.using_default_vpc ? false : anytrue([
    for tier, config in var.config.subnet_topology :
    config.internet_gateway == true
  ])

  has_private_subnets = local.using_default_vpc ? false : anytrue([
    for tier, config in var.config.subnet_topology :
    config.nat_gateway == true
  ])

  has_intra_subnets = local.using_default_vpc ? false : anytrue([
    for tier, config in var.config.subnet_topology :
    config.isolated == true
  ])

  # Tiers that need NAT Gateway (only for custom VPC)
  nat_gateway_tiers = local.using_default_vpc ? [] : [
    for tier, config in var.config.subnet_topology :
    tier if config.nat_gateway == true
  ]

  # Public subnets (for NAT Gateway placement, only for custom VPC)
  public_subnets = local.using_default_vpc ? {} : {
    for subnet_key, subnet_config in local.subnets :
    subnet_key => subnet_config
    if subnet_config.config.internet_gateway == true
  }

  # Get first public subnet per AZ for NAT Gateway placement (only for custom VPC)
  public_subnets_by_az = local.using_default_vpc ? {} : {
    for az_name in local.selected_azs :
    az_name => [
      for subnet_key, subnet_config in local.public_subnets :
      subnet_config
      if subnet_config.az == az_name
    ]
  }

  # AZs that need NAT Gateways (only for custom VPC)
  nat_gateway_azs = local.using_default_vpc ? toset([]) : toset(
    var.config.enable_nat_gateway && local.has_private_subnets ? local.selected_azs : []
  )
}

# VPC (only create when not using default VPC)
resource "aws_vpc" "network" {
  count = var.config.allocation_method != "default" ? 1 : 0

  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = var.config.enable_dns_hostnames
  enable_dns_support   = var.config.enable_dns_support

  tags = merge(
    {
      Name        = "${var.network_name}-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
    },
    var.config.tags
  )
}

# Subnets (only create when not using default VPC)
resource "aws_subnet" "subnets" {
  for_each = var.config.allocation_method != "default" ? local.subnets : {}

  vpc_id                  = aws_vpc.network[0].id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.config.map_public_ip_on_launch

  tags = merge(
    {
      Name        = "${var.network_name}-${each.key}-${var.namespace}"
      NetworkName = var.network_name
      Tier        = each.value.tier
      Namespace   = var.namespace
    },
    each.value.config.tags
  )
}

# Internet Gateway (for public subnets, only when not using default VPC)
resource "aws_internet_gateway" "main" {
  count  = var.config.allocation_method != "default" && local.has_public_subnets ? 1 : 0
  vpc_id = aws_vpc.network[0].id

  tags = merge(
    {
      Name        = "${var.network_name}-igw-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
    },
    var.config.tags
  )
}

# Public Route Table (routes to Internet Gateway, only when not using default VPC)
resource "aws_route_table" "public" {
  count  = var.config.allocation_method != "default" && local.has_public_subnets ? 1 : 0
  vpc_id = aws_vpc.network[0].id

  tags = merge(
    {
      Name        = "${var.network_name}-public-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
      Tier        = "Public"
    },
    var.config.tags
  )
}

# Public Route to Internet
resource "aws_route" "public_internet" {
  count                  = local.has_public_subnets ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main[0].id
}

# Public Route Table Associations
resource "aws_route_table_association" "public" {
  for_each = {
    for subnet_key, subnet_config in local.subnets :
    subnet_key => subnet_config
    if subnet_config.config.internet_gateway == true
  }

  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.public[0].id
}

# Elastic IPs for NAT Gateways (one per AZ)
resource "aws_eip" "nat" {
  for_each = local.nat_gateway_azs
  domain   = "vpc"

  tags = merge(
    {
      Name        = "${var.network_name}-nat-${each.key}-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
    },
    var.config.tags
  )

  depends_on = [aws_internet_gateway.main]
}

# NAT Gateways (one per AZ for high availability)
resource "aws_nat_gateway" "main" {
  for_each      = local.nat_gateway_azs
  allocation_id = aws_eip.nat[each.key].id
  # Place NAT Gateway in first public subnet of each AZ
  subnet_id = [
    for subnet_key, subnet_config in local.public_subnets :
    aws_subnet.subnets[subnet_key].id
    if subnet_config.az == each.key
  ][0]

  tags = merge(
    {
      Name        = "${var.network_name}-nat-${each.key}-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
    },
    var.config.tags
  )

  depends_on = [aws_internet_gateway.main]
}

# Private Route Tables (one per AZ, routes to NAT Gateway in same AZ, only when not using default VPC)
resource "aws_route_table" "private" {
  for_each = var.config.allocation_method != "default" ? local.nat_gateway_azs : toset([])
  vpc_id   = aws_vpc.network[0].id

  tags = merge(
    {
      Name        = "${var.network_name}-private-${each.key}-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
      Tier        = "Private"
    },
    var.config.tags
  )
}

# Private Routes to NAT Gateway
resource "aws_route" "private_nat" {
  for_each               = local.nat_gateway_azs
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}

# Private Route Table Associations
resource "aws_route_table_association" "private" {
  for_each = {
    for subnet_key, subnet_config in local.subnets :
    subnet_key => subnet_config
    if subnet_config.config.nat_gateway == true
  }

  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.private[each.value.az].id
}

# Intra Route Table (no internet routing, isolated, only when not using default VPC)
resource "aws_route_table" "intra" {
  count  = var.config.allocation_method != "default" && local.has_intra_subnets ? 1 : 0
  vpc_id = aws_vpc.network[0].id

  tags = merge(
    {
      Name        = "${var.network_name}-intra-${var.namespace}"
      NetworkName = var.network_name
      Namespace   = var.namespace
      Tier        = "Intra"
    },
    var.config.tags
  )
}

# Intra Route Table Associations
resource "aws_route_table_association" "intra" {
  for_each = {
    for subnet_key, subnet_config in local.subnets :
    subnet_key => subnet_config
    if subnet_config.config.isolated == true
  }

  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.intra[0].id
}
