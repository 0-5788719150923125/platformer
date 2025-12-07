# Config Module Tests
# Verifies that YAML state fragments can be loaded and merged correctly

# Test: Load single state with service configuration
run "load_single_state" {
  command = plan

  variables {
    states     = ["configuration-management-hourly"]
    aws_region = "us-east-2"
  }

  # Should load configuration-management from state
  assert {
    condition     = contains(keys(output.service_configs), "configuration-management")
    error_message = "Should load configuration-management service from state"
  }

  # Should use hourly schedule from state
  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(1 hour)"
    error_message = "Should use hourly schedule from state, got: ${try(output.service_configs["configuration-management"].schedule_expression, "null")}"
  }

  # Should include max_concurrency from state
  assert {
    condition     = output.service_configs["configuration-management"].max_concurrency == "20%"
    error_message = "Should include max_concurrency from state"
  }
}

# Test: Load multiple states with deep merge
run "load_multiple_states_with_merge" {
  command = plan

  variables {
    states = [
      "configuration-management",       # Base service config
      "configuration-management-hourly" # Adds schedule
    ]
    aws_region = "us-east-2"
  }

  # Should load merged configuration-management service
  assert {
    condition     = contains(keys(output.service_configs), "configuration-management")
    error_message = "Should load configuration-management from merged states"
  }

  # Should have schedule from second state (hourly)
  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(1 hour)"
    error_message = "Should deep merge schedule_expression from multiple states"
  }
}

# Test: Empty states list (no services loaded)
run "empty_states_no_services" {
  command = plan

  variables {
    states     = []
    aws_region = "us-east-2"
  }

  # Should work without states
  assert {
    condition     = output.merged_state.services == {}
    error_message = "merged_state services should be empty when no states specified"
  }

  # Should have no services
  assert {
    condition     = length(keys(output.service_configs)) == 0
    error_message = "Should have no services when no states specified"
  }
}

# Test: States load order matters (later states override earlier)
run "states_merge_order" {
  command = plan

  variables {
    states = [
      "configuration-management",       # Base: no schedule_expression
      "configuration-management-hourly" # Override: adds schedule_expression
    ]
    aws_region = "us-east-2"
  }

  # Later state should override with schedule_expression
  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(1 hour)"
    error_message = "Later states should override earlier states (deep merge)"
  }
}

# Test: Loaded states output
run "loaded_states_output" {
  command = plan

  variables {
    states     = ["configuration-management-hourly", "compute-windows-test"]
    aws_region = "us-east-2"
  }

  # Should track which states were loaded
  assert {
    condition     = length(output.loaded_states) == 2
    error_message = "Should output list of loaded states"
  }

  assert {
    condition     = contains(output.loaded_states, "configuration-management-hourly")
    error_message = "Should include configuration-management-hourly in loaded_states"
  }
}
