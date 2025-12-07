# Patch Management Tests
# Verifies that patch management resources are created correctly when configured

# Default mock access values for all runs in this test file
# In production, access module provides these from aws_iam_role.requested resources
variables {
  access_iam_role_arns = {
    "configuration-management-maintenance-window"       = "arn:aws:iam::123456789012:role/test-configuration-management-maintenance-window"
    "configuration-management-dynamic-targeting-lambda" = "arn:aws:iam::123456789012:role/test-configuration-management-dynamic-targeting-lambda"
  }
  access_iam_role_names = {
    "configuration-management-maintenance-window"       = "test-configuration-management-maintenance-window"
    "configuration-management-dynamic-targeting-lambda" = "test-configuration-management-dynamic-targeting-lambda"
  }
}

# Test: Patch management resources created when configured
run "patch_management_enabled" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          windows-test = {
            operating_system                  = "WINDOWS"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 7
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = ["SecurityUpdates"]
                severity       = []
              }
            }]
            classes = ["windows-test"]
          }
        }

        maintenance_windows = {
          windows-monthly = {
            baseline = "windows-test"
            schedule = "cron(0 2 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true
          }
        }
      }
    }
  }

  # Verify baseline created
  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 1
    error_message = "Should create one patch baseline"
  }

  # Verify maintenance window created
  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 1
    error_message = "Should create one maintenance window"
  }

  # Verify service role requested via access_requests (access creates the role)
  assert {
    condition     = length([for r in output.access_requests : r if r.purpose == "maintenance-window"]) == 1
    error_message = "Should request maintenance window service role via access_requests"
  }

  # Verify outputs populated
  assert {
    condition     = output.patch_management_enabled == true
    error_message = "Should report patch management as enabled"
  }
}

# Test: Patch management disabled by default
run "patch_management_disabled" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"
    config         = {}
  }

  # Verify no resources created
  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 0
    error_message = "Should not create baselines when disabled"
  }

  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 0
    error_message = "Should not create windows when disabled"
  }

  assert {
    condition     = output.patch_management_enabled == false
    error_message = "Should report patch management as disabled"
  }
}

# Test: Multiple baselines with class mapping
run "multiple_baselines" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          windows-standard = {
            operating_system                  = "WINDOWS"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 7
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = ["SecurityUpdates"]
                severity       = []
              }
            }]
            classes = ["windows-test", "windows-prod"]
          }

          linux-standard = {
            operating_system                  = "AMAZON_LINUX_2023"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 3
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = ["Security"]
                severity       = []
              }
            }]
            classes = ["rocky-test"]
          }
        }

        maintenance_windows = {
          windows-monthly = {
            baseline = "windows-standard"
            schedule = "cron(0 2 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true
          }
          linux-weekly = {
            baseline = "linux-standard"
            schedule = "cron(0 3 ? * SUN *)"
            duration = 2
            cutoff   = 0
            enabled  = true
          }
        }
      }
    }
  }

  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 2
    error_message = "Should create two baselines"
  }

  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 2
    error_message = "Should create two maintenance windows"
  }

  # Verify baseline class mappings in outputs
  assert {
    condition     = length(output.baselines["windows-standard"].classes) == 2
    error_message = "Windows baseline should map to 2 classes"
  }

  assert {
    condition     = length(output.baselines["linux-standard"].classes) == 1
    error_message = "Linux baseline should map to 1 class"
  }
}

# Test: Disabled maintenance window should not be created
run "disabled_maintenance_window" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          windows-test = {
            operating_system                  = "WINDOWS"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 7
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = ["SecurityUpdates"]
                severity       = []
              }
            }]
            classes = ["windows-test"]
          }
        }

        maintenance_windows = {
          windows-enabled = {
            baseline = "windows-test"
            schedule = "cron(0 2 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true
          }
          windows-disabled = {
            baseline = "windows-test"
            schedule = "cron(0 3 ? * MON *)"
            duration = 2
            cutoff   = 0
            enabled  = false
          }
        }
      }
    }
  }

  # Should only create the enabled window
  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 1
    error_message = "Should only create enabled maintenance windows"
  }

  # Verify the correct window was created
  assert {
    condition     = contains(keys(aws_ssm_maintenance_window.window), "windows-enabled")
    error_message = "Should create the enabled window"
  }
}

# Test: OS version filtering with platform_name and platform_version
run "os_version_filtering" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          rocky9-security = {
            operating_system                  = "ROCKY_LINUX"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 0
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = ["rocky9-vuln-test"]
          }
        }

        maintenance_windows = {
          rocky9-testing = {
            baseline         = "rocky9-security"
            schedule         = "rate(30 minutes)"
            duration         = 1
            cutoff           = 0
            enabled          = true
            platform_name    = "Rocky Linux"
            platform_version = "9"

          }
        }
      }
    }
  }

  # Verify resources created
  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 1
    error_message = "Should create one patch baseline"
  }

  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 1
    error_message = "Should create one maintenance window"
  }

  assert {
    condition     = length(aws_ssm_maintenance_window_target.patch) == 1
    error_message = "Should create one maintenance window target"
  }

  # Verify baseline configuration
  assert {
    condition     = aws_ssm_patch_baseline.baseline["rocky9-security"].operating_system == "ROCKY_LINUX"
    error_message = "Baseline should target ROCKY_LINUX"
  }

  # Verify Linux uses SEVERITY filter key (not MSRC_SEVERITY which is Windows-only)
  assert {
    condition     = aws_ssm_patch_baseline.baseline["rocky9-security"].approval_rule[0].patch_filter[0].key == "SEVERITY"
    error_message = "Linux baselines should use SEVERITY filter key, not MSRC_SEVERITY"
  }
}

# Test: Multiple OS versions with different filters
run "multiple_os_versions" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          rocky9-security = {
            operating_system                  = "ROCKY_LINUX"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 0
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = ["rocky9-prod"]
          }

          rocky8-security = {
            operating_system                  = "ROCKY_LINUX"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 0
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = ["rocky8-prod"]
          }
        }

        maintenance_windows = {
          rocky9-monthly = {
            baseline         = "rocky9-security"
            schedule         = "cron(0 0 ? * SUN#3 *)"
            duration         = 4
            cutoff           = 1
            enabled          = true
            platform_name    = "Rocky Linux"
            platform_version = "9"

          }
          rocky8-monthly = {
            baseline         = "rocky8-security"
            schedule         = "cron(0 0 ? * SUN#2 *)"
            duration         = 4
            cutoff           = 1
            enabled          = true
            platform_name    = "Rocky Linux"
            platform_version = "8"

          }
        }
      }
    }
  }

  # Verify both baselines created
  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 2
    error_message = "Should create two baselines for different Rocky versions"
  }

  # Verify both maintenance windows created
  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 2
    error_message = "Should create two maintenance windows"
  }

  # Verify both have separate targets
  assert {
    condition     = length(aws_ssm_maintenance_window_target.patch) == 2
    error_message = "Should create two maintenance window targets"
  }
}

# Test: Backward compatibility - OS filtering is optional
run "os_filtering_optional" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          windows-standard = {
            operating_system                  = "WINDOWS"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 7
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = ["SecurityUpdates"]
                severity       = []
              }
            }]
            classes = ["windows-test"]
          }
        }

        maintenance_windows = {
          windows-monthly = {
            baseline = "windows-standard"
            schedule = "cron(0 2 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true
            # No platform_name or platform_version specified

          }
        }
      }
    }
  }

  # Should work without OS filtering (backward compatible)
  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 1
    error_message = "Should create baseline without OS filtering"
  }

  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 1
    error_message = "Should create maintenance window without OS filtering"
  }

  assert {
    condition     = length(aws_ssm_maintenance_window_target.patch) == 1
    error_message = "Should create target without OS filtering"
  }
}

# Test: Wildcard targeting with empty classes (OS filters only)
run "wildcard_targeting" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          rocky9-wildcard = {
            operating_system                  = "ROCKY_LINUX"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 0
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = [] # Empty = wildcard targeting
          }
        }

        maintenance_windows = {
          rocky9-wildcard-monthly = {
            baseline = "rocky9-wildcard"
            schedule = "cron(0 0 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true
            dynamic_targeting = {
              platform_name    = "Rocky Linux"
              platform_version = "9"
            }
          }
        }
      }
    }
  }

  # Verify baseline created
  assert {
    condition     = length(aws_ssm_patch_baseline.baseline) == 1
    error_message = "Should create baseline for wildcard targeting"
  }

  # Verify NO patch groups created (empty classes)
  assert {
    condition     = length(aws_ssm_patch_group.baseline_class) == 0
    error_message = "Should not create patch groups when using wildcard targeting"
  }

  # Verify maintenance window created
  assert {
    condition     = length(aws_ssm_maintenance_window.window) == 1
    error_message = "Should create maintenance window"
  }

  # Verify maintenance window target created
  assert {
    condition     = length(aws_ssm_maintenance_window_target.patch) == 1
    error_message = "Should create maintenance window target"
  }
}

# Test: Wildcard targeting validation - must provide OS filters
run "wildcard_targeting_requires_os_filters" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          rocky9-wildcard = {
            operating_system                  = "ROCKY_LINUX"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 0
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = [] # Empty = wildcard targeting
          }
        }

        maintenance_windows = {
          rocky9-wildcard-monthly = {
            baseline = "rocky9-wildcard"
            schedule = "cron(0 0 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true
            # Missing platform_name and platform_version (should fail validation)

          }
        }
      }
    }
  }

  expect_failures = [
    var.config
  ]
}

# Test: Windows baselines use MSRC_SEVERITY, Linux baselines use SEVERITY
run "severity_filter_key_by_os" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    hooks_bucket   = "test-hooks-bucket"

    config = {
      patch_management = {
        baselines = {
          windows-test = {
            operating_system                  = "WINDOWS"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 7
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = ["windows-test"]
          }

          rocky-test = {
            operating_system                  = "ROCKY_LINUX"
            approved_patches_compliance_level = "HIGH"
            approval_rules = [{
              approve_after_days  = 0
              compliance_level    = "HIGH"
              enable_non_security = false
              patch_filter = {
                classification = []
                severity       = ["Critical", "Important"]
              }
            }]
            classes = ["rocky-test"]
          }
        }

        maintenance_windows = {
          windows-monthly = {
            baseline = "windows-test"
            schedule = "cron(0 2 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true

          }
          rocky-monthly = {
            baseline = "rocky-test"
            schedule = "cron(0 3 ? * SUN#3 *)"
            duration = 4
            cutoff   = 1
            enabled  = true

          }
        }
      }
    }
  }

  # Verify Windows uses MSRC_SEVERITY
  assert {
    condition     = aws_ssm_patch_baseline.baseline["windows-test"].approval_rule[0].patch_filter[0].key == "MSRC_SEVERITY"
    error_message = "Windows baselines should use MSRC_SEVERITY filter key"
  }

  # Verify Linux uses SEVERITY
  assert {
    condition     = aws_ssm_patch_baseline.baseline["rocky-test"].approval_rule[0].patch_filter[0].key == "SEVERITY"
    error_message = "Linux baselines should use SEVERITY filter key"
  }
}
