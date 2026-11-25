# Networking outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "vpc" {
  description = "VPC metadata"
  value       = local.aws_output_vpc
}

output "subnets_by_tier" {
  description = "Subnets grouped by tier (private/public/intra) with all subnet IDs and CIDRs"
  value       = local.aws_output_subnets_by_tier
}

output "all_subnets" {
  description = "Complete subnet inventory with metadata"
  value       = local.aws_output_all_subnets
}

output "nat_gateways" {
  description = "NAT Gateway Elastic IPs for egress traffic allowlisting"
  value       = local.aws_output_nat_gateways
}

output "internet_gateway" {
  description = "Internet Gateway metadata"
  value       = local.aws_output_internet_gateway
}

output "route_tables" {
  description = "Route table IDs by type"
  value       = local.aws_output_route_tables
}

output "cidr_allocation" {
  description = "CIDR allocation metadata"
  value       = local.aws_output_cidr_allocation
}

output "availability_zones" {
  description = "Availability zone selection metadata"
  value       = local.aws_output_availability_zones
}

output "network_summary" {
  description = "High-level network configuration summary"
  value       = local.aws_output_network_summary
}
