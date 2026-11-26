# Config Module Tests
# Verifies that YAML fragments can be loaded and merged correctly

# Test: Load a single fragment with service configuration
run "load_single_state" {
  command = plan

  variables {
    fragments  = ["configuration-management-hourly"]
    aws_region = "us-east-2"
    # Test fixtures live in the repo-level tests/fragments dir (fragments/ is user config)
    fragment_dirs = ["../tests/fragments"]
  }

  # Should load configuration-management from the fragment
  assert {
    condition     = contains(keys(output.service_configs), "configuration-management")
    error_message = "Should load configuration-management service from the fragment"
  }

  # Should use hourly schedule from the fragment
  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(1 hour)"
    error_message = "Should use hourly schedule from state, got: ${try(output.service_configs["configuration-management"].schedule_expression, "null")}"
  }

  # Should include max_concurrency from the fragment
  assert {
    condition     = output.service_configs["configuration-management"].max_concurrency == "20%"
    error_message = "Should include max_concurrency from state"
  }
}

# Test: Load multiple fragments with deep merge
run "load_multiple_fragments_with_merge" {
  command = plan

  variables {
    fragments = [
      "configuration-management",       # Base service config
      "configuration-management-hourly" # Adds schedule
    ]
    aws_region = "us-east-2"
    # Test fixtures live in the repo-level tests/fragments dir (fragments/ is user config)
    fragment_dirs = ["../tests/fragments"]
  }

  # Should load merged configuration-management service
  assert {
    condition     = contains(keys(output.service_configs), "configuration-management")
    error_message = "Should load configuration-management from the merged fragments"
  }

  # Should have schedule from second state (hourly)
  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(1 hour)"
    error_message = "Should deep merge schedule_expression from multiple fragments"
  }
}

# Test: Empty fragments list (no services loaded)
run "empty_fragments_no_services" {
  command = plan

  variables {
    fragments  = []
    aws_region = "us-east-2"
    # Test fixtures live in the repo-level tests/fragments dir (fragments/ is user config)
    fragment_dirs = ["../tests/fragments"]
  }

  # Should work without fragments
  assert {
    condition     = output.merged.services == {}
    error_message = "merged services should be empty when no fragments specified"
  }

  # Should have no services
  assert {
    condition     = length(keys(output.service_configs)) == 0
    error_message = "Should have no services when no fragments specified"
  }
}

# Test: Fragments load order matters (later fragments override earlier)
run "fragments_merge_order" {
  command = plan

  variables {
    fragments = [
      "configuration-management",       # Base: no schedule_expression
      "configuration-management-hourly" # Override: adds schedule_expression
    ]
    aws_region = "us-east-2"
    # Test fixtures live in the repo-level tests/fragments dir (fragments/ is user config)
    fragment_dirs = ["../tests/fragments"]
  }

  # Later state should override with schedule_expression
  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(1 hour)"
    error_message = "Later fragments should override earlier fragments (deep merge)"
  }
}

# Test: Loaded fragments output
run "loaded_fragments_output" {
  command = plan

  variables {
    fragments  = ["configuration-management-hourly", "windows-multi-tenant"]
    aws_region = "us-east-2"
    # Test fixtures live in the repo-level tests/fragments dir (fragments/ is user config)
    fragment_dirs = ["../tests/fragments"]
  }

  # Should track which fragments were loaded
  assert {
    condition     = length(output.loaded_fragments) == 2
    error_message = "Should output list of loaded fragments"
  }

  assert {
    condition     = contains(output.loaded_fragments, "configuration-management-hourly")
    error_message = "Should include configuration-management-hourly in loaded_fragments"
  }
}
