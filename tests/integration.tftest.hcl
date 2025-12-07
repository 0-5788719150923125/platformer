# Integration tests for cross-module interactions
# Uses test-specific state fragments in tests/states/ (not production states/)

# Disable workspace file overrides so test variables are used directly
variables {
  workspace_overrides = false
}

# =============================================================================
# Networking + Compute
# =============================================================================

run "compute_with_custom_vpc" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["compute-vpc"]
  }

  assert {
    condition     = length(module.networks) == 1
    error_message = "Network module should be created"
  }

  assert {
    condition     = length(module.compute) == 1
    error_message = "Compute module should be created"
  }

  assert {
    condition     = length(module.networks["shared"].subnets_by_tier) > 0
    error_message = "Subnets should be created and organized by tier"
  }

  assert {
    condition     = length(regexall("^10\\.150\\..*", module.networks["shared"].vpc.cidr_block)) > 0
    error_message = "VPC CIDR should be deterministically generated (10.150.x.x for account 555555555555)"
  }

  assert {
    condition     = length(module.networks["shared"].availability_zones.selected_azs) == 2
    error_message = "Should deploy across 2 availability zones"
  }

  assert {
    condition     = length(module.networks["shared"].nat_gateways) == 2
    error_message = "Should create 2 NAT gateways (one per AZ)"
  }

  assert {
    condition     = module.compute[0].config.total_instances > 0
    error_message = "At least one instance should be created"
  }
}

run "compute_with_default_vpc_fallback" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["compute-default-vpc"]
  }

  assert {
    condition     = length(module.compute) == 1
    error_message = "Compute module should be created"
  }

  assert {
    condition     = contains(keys(module.networks), "default")
    error_message = "Default network should be auto-created when no networks defined"
  }

  assert {
    condition     = module.networks["default"].cidr_allocation.method == "default"
    error_message = "Default network should use AWS default VPC"
  }

  assert {
    condition     = module.compute[0].config.total_instances > 0
    error_message = "At least one instance should be created"
  }
}

run "multi_vpc_isolation" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["multi-vpc"]
  }

  assert {
    condition     = length(module.networks) == 2
    error_message = "Should create 2 VPCs (shared-services + app-tier)"
  }

  assert {
    condition     = contains(keys(module.networks), "shared-services") && contains(keys(module.networks), "app-tier")
    error_message = "Should have shared-services and app-tier networks"
  }

  assert {
    condition     = module.networks["app-tier"].vpc.cidr_block == "10.100.0.0/16"
    error_message = "App-tier VPC should use explicit CIDR 10.100.0.0/16"
  }

  # 1 tenant × (1 monitoring + 2 web-server) = 3 instances
  assert {
    condition     = module.compute[0].config.total_instances == 3
    error_message = "Should create 3 instances (1 monitoring + 2 web-server)"
  }
}

run "network_only_deployment" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["network-only"]
  }

  assert {
    condition     = length(module.networks) == 1
    error_message = "Network module should be created"
  }

  assert {
    condition     = length(module.compute) == 0
    error_message = "Compute module should NOT be created"
  }

  assert {
    condition = alltrue([
      contains(keys(module.networks["shared"].subnets_by_tier), "private"),
      contains(keys(module.networks["shared"].subnets_by_tier), "public"),
      contains(keys(module.networks["shared"].subnets_by_tier), "intra"),
    ])
    error_message = "Should have private, public, and intra subnet tiers"
  }

  assert {
    condition     = length(module.networks["shared"].availability_zones.selected_azs) == 3
    error_message = "Should deploy across 3 availability zones"
  }

  assert {
    condition     = length(module.networks["shared"].nat_gateways) == 3
    error_message = "Should create 3 NAT gateways (one per AZ)"
  }
}

# =============================================================================
# Compute variations
# =============================================================================

run "eks_cluster" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["eks-cluster"]
  }

  assert {
    condition     = length(module.compute) == 1
    error_message = "Compute module should be created"
  }

  assert {
    condition     = length(module.compute[0].eks_clusters) == 1
    error_message = "Should create 1 EKS cluster"
  }
}

run "windows_multi_tenant" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["windows-multi-tenant"]
  }

  assert {
    condition     = length(module.compute) == 1
    error_message = "Compute module should be created"
  }

  # 3 tenants × 1 class × count 1 = 3 instances
  assert {
    condition     = module.compute[0].config.total_instances == 3
    error_message = "Should create 3 instances (3 tenants × 1 instance each)"
  }

  assert {
    condition     = length(module.compute[0].config.tenants) == 3
    error_message = "Should have 3 tenants"
  }
}

# =============================================================================
# Applications + dependency inversion
# =============================================================================

run "applications_dependency_inversion" {
  command = plan

  variables {
    states = ["applications"]
  }

  assert {
    condition     = length(module.compute[0].application_requests) > 0
    error_message = "Compute should output application_requests"
  }

  assert {
    condition     = module.compute[0].application_requests[0].script == "install-postgresql.sh"
    error_message = "Application request should reference install-postgresql.sh"
  }

  assert {
    condition     = module.compute[0].application_requests[0].params.POSTGRES_VERSION == "15"
    error_message = "Application request should pass POSTGRES_VERSION=15"
  }

  assert {
    condition     = length([for req in module.applications[0].requests : req if req.type == "ssm"]) > 0
    error_message = "Applications should produce SSM requests"
  }

  assert {
    condition     = length(module.configuration_management[0].application_associations) > 0
    error_message = "Configuration management should create SSM associations"
  }

  assert {
    condition     = length(module.storage) > 0
    error_message = "Storage should auto-enable for application scripts"
  }
}

run "mixed_application_types" {
  command = plan

  variables {
    states = ["mixed-applications"]
  }

  # Should have both user-data and SSM application requests
  assert {
    condition     = length(module.compute[0].application_requests) == 4
    error_message = "Should have 4 application requests (2 user-data + 2 SSM)"
  }

  assert {
    condition     = length([for req in module.applications[0].requests : req if req.type == "user-data"]) == 2
    error_message = "Should have 2 user-data application requests"
  }

  assert {
    condition     = length([for req in module.applications[0].requests : req if req.type == "ssm"]) == 2
    error_message = "Should have 2 SSM application requests"
  }

  # SSM apps auto-enable configuration-management and storage
  assert {
    condition     = length(module.configuration_management) == 1
    error_message = "Configuration management should auto-enable for SSM applications"
  }

  assert {
    condition     = length(module.storage) == 1
    error_message = "Storage should auto-enable for application scripts"
  }
}

# =============================================================================
# Configuration management
# =============================================================================

run "hybrid_activations" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["hybrid-activations"]
  }

  assert {
    condition     = length(module.configuration_management) == 1
    error_message = "Configuration management should be created"
  }

  assert {
    condition     = length(module.configuration_management[0].hybrid_activations) > 0
    error_message = "Should create hybrid activations"
  }

  assert {
    condition     = contains(keys(module.configuration_management[0].hybrid_activations), "developer-workstations")
    error_message = "Should have developer-workstations activation"
  }
}

run "patch_management_with_maintenance_windows" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["patch-management"]
  }

  assert {
    condition     = length(module.configuration_management) == 1
    error_message = "Configuration management should be created"
  }

  assert {
    condition     = module.configuration_management[0].patch_management_enabled == true
    error_message = "Patch management should be enabled"
  }

  assert {
    condition     = length(module.compute) == 1
    error_message = "Compute should auto-enable for patch management targets"
  }
}

# =============================================================================
# ArchOrchestrator (ECS + RDS + S3)
# =============================================================================

run "archorchestrator_full_stack" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    states      = ["archorchestrator"]
  }

  assert {
    condition     = length(module.archorchestrator) == 1
    error_message = "ArchOrchestrator should be created"
  }

  # Auto-enables storage (RDS+S3) and compute (ECS)
  assert {
    condition     = length(module.storage) == 1
    error_message = "Storage should auto-enable for ArchOrchestrator RDS+S3"
  }

  assert {
    condition     = length(module.compute) == 1
    error_message = "Compute should auto-enable for ArchOrchestrator ECS"
  }

  assert {
    condition     = length(module.compute[0].ecs_clusters) > 0
    error_message = "Should create ECS clusters"
  }
}
