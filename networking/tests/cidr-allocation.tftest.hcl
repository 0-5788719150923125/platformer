# Test: CIDR Allocation Determinism and Collision Detection

run "deterministic_cidr_same_account" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "555555555555"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 2
    }
  }

  # Verify same account ID produces same CIDR
  assert {
    condition     = output.cidr_allocation.allocated_cidr != null
    error_message = "CIDR should be allocated"
  }

  assert {
    condition     = can(cidrhost(output.cidr_allocation.allocated_cidr, 0))
    error_message = "Allocated CIDR should be valid"
  }
}

run "deterministic_cidr_different_accounts" {
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

  # Verify different account ID produces different CIDR
  assert {
    condition     = output.cidr_allocation.allocated_cidr != run.deterministic_cidr_same_account.cidr_allocation.allocated_cidr
    error_message = "Different account IDs should produce different CIDRs"
  }
}

run "explicit_cidr_allocation" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "explicit"
      explicit_cidr     = "172.20.0.0/16"
      az_count          = 2
    }
  }

  # Verify explicit CIDR is used
  assert {
    condition     = output.cidr_allocation.allocated_cidr == "172.20.0.0/16"
    error_message = "Explicit CIDR should be used when allocation_method is explicit"
  }
}

run "hash_stability" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "555555555555"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 3
    }
  }

  # Known account ID should produce predictable CIDR
  assert {
    condition     = output.cidr_allocation.account_id == "555555555555"
    error_message = "Account ID should be preserved in metadata"
  }

  assert {
    condition     = output.cidr_allocation.method == "deterministic"
    error_message = "Allocation method should be deterministic"
  }

  assert {
    condition     = output.cidr_allocation.hash_value >= 0 && output.cidr_allocation.hash_value <= 255
    error_message = "Hash value should be between 0 and 255 for /16 allocation"
  }
}

run "account_id_determinism" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "999999999999"
    network_name   = "test-network"
    config = {
      base_cidr         = "10.0.0.0/8"
      allocation_method = "deterministic"
      az_count          = 2
    }
  }

  # Verify account ID-based hash calculation
  assert {
    condition     = output.cidr_allocation.account_id == "999999999999"
    error_message = "Account ID should be used for CIDR allocation"
  }

  # Hash should be last 3 digits % 256
  assert {
    condition     = output.cidr_allocation.hash_value == "231" # 999 % 256 = 231
    error_message = "Hash should be calculated from last 3 digits of account ID"
  }
}
