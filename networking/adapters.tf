# The AWS adapter's outputs, one local each. These are the values when the
# workspace doesn't use AWS; aws/wiring_override.tf.tmpl (linked in as
# adapter_aws_override.tf by scripts/providers.sh) points each at module.aws.
# One local per output keeps dependencies per output: referencing the module as
# a whole would tie every output to every other and close request round-trips
# (e.g. archivist -> storage -> archivist) into cycles.
locals {
  aws_wired = false

  aws_output_vpc                = {}
  aws_output_subnets_by_tier    = {}
  aws_output_all_subnets        = {}
  aws_output_nat_gateways       = {}
  aws_output_internet_gateway   = null
  aws_output_route_tables       = {}
  aws_output_cidr_allocation    = {}
  aws_output_availability_zones = {}
  aws_output_network_summary    = {}
}
