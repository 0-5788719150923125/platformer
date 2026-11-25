# Test: Gateway Creation and Routing

run "nat_gateway_creation" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr          = "10.0.0.0/8"
      allocation_method  = "deterministic"
      az_count           = 3
      enable_nat_gateway = true
    }
  }

  # Verify NAT gateways created (one per AZ)
  assert {
    condition     = length(output.nat_gateways) == 3
    error_message = "Should create 3 NAT gateways (one per AZ)"
  }

  # Verify NAT gateway resources will be created
  assert {
    condition     = length(aws_nat_gateway.main) == 3
    error_message = "Should create 3 NAT gateway resources"
  }

  # Verify network summary reflects NAT gateway presence
  assert {
    condition     = output.network_summary.has_nat == true
    error_message = "Network summary should indicate NAT gateway is enabled"
  }
}

run "nat_gateway_disabled" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr          = "10.0.0.0/8"
      allocation_method  = "deterministic"
      az_count           = 3
      enable_nat_gateway = false
      subnet_topology = {
        private = {
          cidr_newbits = 8
          offset       = 0
          nat_gateway  = false # Disabled
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

  # Verify no NAT gateways created
  assert {
    condition     = length(output.nat_gateways) == 0
    error_message = "Should not create NAT gateways when disabled"
  }

  assert {
    condition     = output.network_summary.has_nat == false
    error_message = "Network summary should indicate NAT gateway is disabled"
  }
}

run "internet_gateway_creation" {
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
        public = {
          cidr_newbits            = 10
          offset                  = 100
          internet_gateway        = true
          map_public_ip_on_launch = true
        }
      }
    }
  }

  # Verify internet gateway created
  assert {
    condition     = output.internet_gateway != null
    error_message = "Should create internet gateway when public subnets exist"
  }

  assert {
    condition     = length(aws_internet_gateway.main) == 1
    error_message = "Should create internet gateway resource"
  }

  assert {
    condition     = output.network_summary.has_igw == true
    error_message = "Network summary should indicate internet gateway is enabled"
  }
}

run "route_tables_created" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 2
    }
  }

  # Verify public route table exists
  assert {
    condition     = output.route_tables.public != null
    error_message = "Should create public route table"
  }

  # Verify private route tables exist (one per AZ)
  assert {
    condition     = length(output.route_tables.private) == 2
    error_message = "Should create 2 private route tables (one per AZ)"
  }

  # Verify intra route table exists
  assert {
    condition     = output.route_tables.intra != null
    error_message = "Should create intra route table"
  }
}

run "isolated_network_no_gateways" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr          = "10.0.0.0/8"
      allocation_method  = "deterministic"
      az_count           = 2
      enable_nat_gateway = false
      subnet_topology = {
        intra = {
          cidr_newbits = 8
          offset       = 0
          isolated     = true
        }
      }
    }
  }

  # Verify no NAT gateways
  assert {
    condition     = length(output.nat_gateways) == 0
    error_message = "Isolated network should not have NAT gateways"
  }

  # Verify no internet gateway
  assert {
    condition     = output.internet_gateway == null
    error_message = "Isolated network should not have internet gateway"
  }

  # Verify network summary reflects isolated state
  assert {
    condition     = output.network_summary.has_nat == false && output.network_summary.has_igw == false
    error_message = "Network summary should indicate no internet connectivity"
  }
}
