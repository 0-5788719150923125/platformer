# Root wiring test for states_paths
# Module-level behavior (precedence, missing dirs, catalogs, tfvars parsing,
# archiving) is covered in config/tests, workspaces/tests and archivist/tests.
# This checks the root passes user paths through, ahead of the repo dirs.

variables {
  workspace_overrides = false
  aws_profile         = "example-platform-dev"
}

run "user_path_wins_and_reaches_consumers" {
  command = plan

  variables {
    # Relative to the repo root. user-a overrides tests/states' copy.
    states_paths = ["config/tests/fixtures/user-a"]
    states       = ["configuration-management-hourly"]
  }

  assert {
    condition     = startswith(module.config.state_paths["configuration-management-hourly"], abspath("config/tests/fixtures/user-a/"))
    error_message = "Relative states_paths should resolve against the repo root and win, got: ${module.config.state_paths["configuration-management-hourly"]}"
  }

  assert {
    condition     = module.config.service_configs["configuration-management"].schedule_expression == "rate(5 minutes)"
    error_message = "Service config should come from the user fragment"
  }

  # Catalog: user fragments plus states/, but not tests/states fixtures
  assert {
    condition = (
      contains(keys(module.config.available_states), "configuration-management-hourly") &&
      !contains(keys(module.config.available_states), "network-only")
    )
    error_message = "Catalog should include user fragments and exclude tests/states"
  }
}
