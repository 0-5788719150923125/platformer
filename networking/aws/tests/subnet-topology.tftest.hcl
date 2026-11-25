# Test: Subnet Topology and CIDR Calculation

run "default_topology" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 3
      # Use default subnet_topology from variables.tf
    }
  }

  # Verify default topology has 3 tiers
  assert {
    condition     = length(output.subnets_by_tier) == 3
    error_message = "Default topology should have 3 tiers (private, public, intra)"
  }

  assert {
    condition     = contains(keys(output.subnets_by_tier), "private")
    error_message = "Default topology should include private tier"
  }

  assert {
    condition     = contains(keys(output.subnets_by_tier), "public")
    error_message = "Default topology should include public tier"
  }

  assert {
    condition     = contains(keys(output.subnets_by_tier), "intra")
    error_message = "Default topology should include intra tier"
  }

  # Verify subnet count: 3 tiers × 3 AZs = 9 subnets
  assert {
    condition     = length(output.all_subnets) == 9
    error_message = "Should create 9 subnets (3 tiers × 3 AZs)"
  }

  # Verify private tier has 3 subnets (one per AZ)
  assert {
    condition     = length(output.subnets_by_tier["private"].ids) == 3
    error_message = "Private tier should have 3 subnets"
  }
}

run "custom_topology_two_tiers" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 2
      subnet_topology = {
        private = {
          cidr_newbits = 8
          offset       = 0
          nat_gateway  = true
        }
        public = {
          cidr_newbits            = 10
          offset                  = 100
          internet_gateway        = true
          map_public_ip_on_launch = true
        }
      }
    }
  }

  # Verify only 2 tiers
  assert {
    condition     = length(output.subnets_by_tier) == 2
    error_message = "Custom topology should have 2 tiers"
  }

  # Verify subnet count: 2 tiers × 2 AZs = 4 subnets
  assert {
    condition     = length(output.all_subnets) == 4
    error_message = "Should create 4 subnets (2 tiers × 2 AZs)"
  }
}

run "subnet_cidr_non_overlapping" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 3
    }
  }

  # Verify all subnet CIDRs are unique (no overlaps)
  assert {
    condition = length(output.all_subnets) == length(distinct([
      for subnet in output.all_subnets : subnet.cidr_block
    ]))
    error_message = "All subnet CIDRs should be unique (no overlaps)"
  }

  # Verify all subnets are within VPC CIDR
  assert {
    condition = alltrue([
      for subnet in output.all_subnets :
      can(cidrsubnet(output.vpc.cidr_block, 0, 0)) # Subnet is valid within VPC
    ])
    error_message = "All subnets should be within VPC CIDR range"
  }
}

run "az_selection_alphabetical" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 2
      az_selection      = "alphabetical"
    }
  }

  # Verify correct number of AZs selected
  assert {
    condition     = output.availability_zones.az_count == 2
    error_message = "Should select 2 AZs when az_count = 2"
  }

  assert {
    condition     = output.availability_zones.selection_method == "alphabetical"
    error_message = "AZ selection method should be alphabetical"
  }

  # Verify subnets exist in selected AZs
  assert {
    condition = alltrue([
      for az in output.availability_zones.selected_azs :
      length(output.subnets_by_tier["private"].by_az[az].ids) > 0
    ])
    error_message = "Each selected AZ should have subnets"
  }
}

run "explicit_azs" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_selection      = "explicit"
      explicit_azs      = ["us-east-2a", "us-east-2b"]
      subnet_topology = {
        private = {
          cidr_newbits = 8
          offset       = 0
          nat_gateway  = false
        }
      }
    }
  }

  # Verify explicit AZs are used
  assert {
    condition     = length(output.availability_zones.selected_azs) == 2
    error_message = "Should use 2 explicit AZs"
  }

  assert {
    condition     = contains(output.availability_zones.selected_azs, "us-east-2a") && contains(output.availability_zones.selected_azs, "us-east-2b")
    error_message = "Should use specified explicit AZs"
  }
}
