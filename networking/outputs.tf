# Networking outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "vpc" {
  description = "VPC metadata"
  value       = module.aws.vpc
}

output "subnets_by_tier" {
  description = "Subnets grouped by tier (private/public/intra) with all subnet IDs and CIDRs"
  value       = module.aws.subnets_by_tier
}

output "all_subnets" {
  description = "Complete subnet inventory with metadata"
  value       = module.aws.all_subnets
}

output "nat_gateways" {
  description = "NAT Gateway Elastic IPs for egress traffic allowlisting"
  value       = module.aws.nat_gateways
}

output "internet_gateway" {
  description = "Internet Gateway metadata"
  value       = module.aws.internet_gateway
}

output "route_tables" {
  description = "Route table IDs by type"
  value       = module.aws.route_tables
}

output "cidr_allocation" {
  description = "CIDR allocation metadata"
  value       = module.aws.cidr_allocation
}

output "availability_zones" {
  description = "Availability zone selection metadata"
  value       = module.aws.availability_zones
}

output "network_summary" {
  description = "High-level network configuration summary"
  value       = module.aws.network_summary
}
