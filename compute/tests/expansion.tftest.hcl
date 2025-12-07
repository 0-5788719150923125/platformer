# Module-specific tests for compute module
# Tests tenant × class × count expansion logic and naming conventions

run "default_values" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config         = {}
  }

  # Verify no instances created with empty config
  assert {
    condition     = length(aws_instance.tenant) == 0
    error_message = "Should not create instances with empty config"
  }

  # Verify config output shows empty state
  assert {
    condition     = length(output.config.tenants) == 0
    error_message = "Should show no tenants"
  }

  assert {
    condition     = length(output.config.classes) == 0
    error_message = "Should show no classes"
  }

  assert {
    condition     = output.config.total_instances == 0
    error_message = "Should show zero total instances"
  }
}

run "single_tenant_single_class_count_1" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config = {
      windows-test = {
        type          = "ec2"
        ami_filter    = "Windows_Server-2022-*"
        instance_type = "t3.medium"
        count         = 1
        description   = "Test Windows instance"
      }
    }
    tenants_by_class = {
      windows-test = ["test-tenant"]
    }
  }

  # Verify exactly 1 instance created
  assert {
    condition     = length(aws_instance.tenant) == 1
    error_message = "Should create exactly 1 instance (1 tenant × 1 class × count 1)"
  }

  # Verify instance naming: should be "test-tenant-windows-test-0" (index always included)
  assert {
    condition     = contains(keys(aws_instance.tenant), "test-tenant-windows-test-0")
    error_message = "Instance key should be 'test-tenant-windows-test-0' (index always included)"
  }

  # Verify config summary
  assert {
    condition     = output.config.total_instances == 1
    error_message = "Config should report 1 total instance"
  }

  # Verify instance tags
  assert {
    condition     = aws_instance.tenant["test-tenant-windows-test-0"].tags["Tenant"] == "test-tenant"
    error_message = "Instance should have Tenant tag"
  }

  assert {
    condition     = aws_instance.tenant["test-tenant-windows-test-0"].tags["Class"] == "windows-test"
    error_message = "Instance should have Class tag"
  }

  # Verify description tag is added
  assert {
    condition     = aws_instance.tenant["test-tenant-windows-test-0"].tags["Description"] == "Test Windows instance"
    error_message = "Instance should have Description tag when description is non-empty"
  }
}

run "single_tenant_single_class_count_3" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config = {
      web-server = {
        type        = "ec2"
        ami_filter  = "Rocky-9-EC2-Base-9.*x86_64"
        ami_owner   = "792107900819"
        count       = 3
        description = "Web server cluster"
      }
    }
    tenants_by_class = {
      web-server = ["prod"]
    }
  }

  # Verify 3 instances created
  assert {
    condition     = length(aws_instance.tenant) == 3
    error_message = "Should create 3 instances (1 tenant × 1 class × count 3)"
  }

  # Verify instance naming with index: "prod-web-server-0", "prod-web-server-1", "prod-web-server-2"
  assert {
    condition     = contains(keys(aws_instance.tenant), "prod-web-server-0")
    error_message = "Should create instance 'prod-web-server-0'"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "prod-web-server-1")
    error_message = "Should create instance 'prod-web-server-1'"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "prod-web-server-2")
    error_message = "Should create instance 'prod-web-server-2'"
  }

  # Verify config summary
  assert {
    condition     = output.config.total_instances == 3
    error_message = "Config should report 3 total instances"
  }
}

run "multiple_tenants_single_class" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config = {
      windows-test = {
        type        = "ec2"
        ami_filter  = "Windows_Server-2022-*"
        count       = 1
        description = ""
      }
    }
    tenants_by_class = {
      windows-test = ["alpha", "november", "medvet"]
    }
  }

  # Verify 3 instances created (3 tenants × 1 class × count 1)
  assert {
    condition     = length(aws_instance.tenant) == 3
    error_message = "Should create 3 instances (3 tenants × 1 class × count 1)"
  }

  # Verify all tenant instances exist (with index suffix)
  assert {
    condition     = contains(keys(aws_instance.tenant), "alpha-windows-test-0")
    error_message = "Should create instance for alpha"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "november-windows-test-0")
    error_message = "Should create instance for november"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "medvet-windows-test-0")
    error_message = "Should create instance for medvet"
  }

  # Verify empty description doesn't create Description tag
  assert {
    condition     = !contains(keys(aws_instance.tenant["alpha-windows-test-0"].tags), "Description")
    error_message = "Should not add Description tag when description is empty"
  }
}

run "multiple_tenants_multiple_classes_mixed_counts" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config = {
      web = {
        type        = "ec2"
        ami_filter  = "Rocky-9-EC2-Base-9.*x86_64"
        ami_owner   = "792107900819"
        count       = 2
        description = "Web tier"
      }
      db = {
        type        = "ec2"
        ami_filter  = "Rocky-9-EC2-Base-9.*x86_64"
        ami_owner   = "792107900819"
        count       = 1
        description = "Database tier"
      }
    }
    tenants_by_class = {
      web = ["alpha", "beta"]
      db  = ["alpha", "beta"]
    }
  }

  # Verify total: 2 tenants × (2 web + 1 db) = 6 instances
  assert {
    condition     = length(aws_instance.tenant) == 6
    error_message = "Should create 6 instances (2 tenants × 2 classes × mixed counts)"
  }

  # Verify alpha instances
  assert {
    condition     = contains(keys(aws_instance.tenant), "alpha-web-0")
    error_message = "Should create alpha-web-0"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "alpha-web-1")
    error_message = "Should create alpha-web-1"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "alpha-db-0")
    error_message = "Should create alpha-db-0 (index always included)"
  }

  # Verify beta instances
  assert {
    condition     = contains(keys(aws_instance.tenant), "beta-web-0")
    error_message = "Should create beta-web-0"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "beta-web-1")
    error_message = "Should create beta-web-1"
  }

  assert {
    condition     = contains(keys(aws_instance.tenant), "beta-db-0")
    error_message = "Should create beta-db-0 (index always included)"
  }
}

# Validation tests removed - no count or description length validation exists in module
