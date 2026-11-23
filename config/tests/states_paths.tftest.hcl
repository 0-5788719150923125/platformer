# Config Module Tests - search-path precedence (states_paths)
# The root module passes user states_paths ahead of states/ and tests/states/.
# These runs exercise the same ordering through states_dirs directly.

variables {
  aws_region = "us-east-2"
}

run "first_dir_wins_on_name_conflict" {
  command = plan

  variables {
    states      = ["configuration-management-hourly"]
    states_dirs = ["tests/fixtures/user-a", "../tests/states"]
  }

  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(5 minutes)"
    error_message = "User dir should override tests/states, got: ${try(output.service_configs["configuration-management"].schedule_expression, "null")}"
  }

  # The override replaces the whole file - nothing leaks in from the shadowed copy
  assert {
    condition     = !can(output.service_configs["configuration-management"].max_concurrency)
    error_message = "Shadowed fragment should not be merged in"
  }

  assert {
    condition     = endswith(output.state_paths["configuration-management-hourly"], "tests/fixtures/user-a/configuration-management-hourly.yaml")
    error_message = "state_paths should point at the user copy, got: ${output.state_paths["configuration-management-hourly"]}"
  }
}

run "user_dirs_keep_their_order" {
  command = plan

  variables {
    states      = ["configuration-management-hourly"]
    states_dirs = ["tests/fixtures/user-b", "tests/fixtures/user-a", "../tests/states"]
  }

  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(2 hours)"
    error_message = "Earlier user dir should win, got: ${try(output.service_configs["configuration-management"].schedule_expression, "null")}"
  }
}

run "falls_through_to_later_dirs" {
  command = plan

  variables {
    # configuration-management lives only in tests/states, user-only only in user-b
    states      = ["configuration-management", "user-only"]
    states_dirs = ["tests/fixtures/empty", "tests/fixtures/user-b", "../tests/states"]
  }

  assert {
    condition     = contains(keys(output.service_configs), "configuration-management")
    error_message = "Fragment missing from user dirs should load from a later dir"
  }

  assert {
    condition     = output.service_configs["user-only"].enabled == true
    error_message = "Fragment that only exists in a user dir should load"
  }

  assert {
    condition     = endswith(output.state_paths["configuration-management"], "../tests/states/configuration-management.yaml")
    error_message = "state_paths should point at tests/states, got: ${output.state_paths["configuration-management"]}"
  }
}

run "absolute_paths_are_used_verbatim" {
  command = plan

  variables {
    states      = ["configuration-management-hourly"]
    states_dirs = [abspath("tests/fixtures/user-a"), "../tests/states"]
  }

  assert {
    condition     = output.service_configs["configuration-management"].schedule_expression == "rate(5 minutes)"
    error_message = "Absolute user dir should be searched first"
  }

  assert {
    condition     = startswith(output.state_paths["configuration-management-hourly"], "/")
    error_message = "state_paths should keep the absolute path, got: ${output.state_paths["configuration-management-hourly"]}"
  }
}

run "missing_dir_fails" {
  command = plan

  variables {
    states      = ["configuration-management-hourly"]
    states_dirs = ["tests/fixtures/does-not-exist", "../tests/states"]
  }

  expect_failures = [var.states_dirs]
}

run "file_is_not_a_dir" {
  command = plan

  variables {
    states      = ["configuration-management-hourly"]
    states_dirs = ["tests/fixtures/user-b/user-only.yaml", "../tests/states"]
  }

  expect_failures = [var.states_dirs]
}

run "catalog_defaults_to_states_dirs" {
  command = plan

  variables {
    states      = []
    states_dirs = ["tests/fixtures/user-a", "tests/fixtures/user-b", "../tests/states"]
  }

  assert {
    condition     = contains(keys(output.available_states), "user-only") && contains(keys(output.available_states), "network-only")
    error_message = "Catalog should list fragments from every dir"
  }

  assert {
    condition     = endswith(output.available_states["configuration-management-hourly"], "user-a/configuration-management-hourly.yaml")
    error_message = "Catalog should apply first-match-wins, got: ${output.available_states["configuration-management-hourly"]}"
  }
}

run "catalog_dirs_narrow_the_catalog" {
  command = plan

  variables {
    states       = ["network-only"]
    states_dirs  = ["tests/fixtures/user-b", "../tests/states"]
    catalog_dirs = ["tests/fixtures/user-b"]
  }

  # Selected states still resolve from every search dir...
  assert {
    condition     = contains(keys(output.state_paths), "network-only")
    error_message = "catalog_dirs must not affect state resolution"
  }

  # ...but the catalog only covers catalog_dirs
  assert {
    condition     = jsonencode(keys(output.available_states)) == jsonencode(["configuration-management-hourly", "user-only"])
    error_message = "Catalog should only list catalog_dirs fragments, got: ${jsonencode(keys(output.available_states))}"
  }
}

run "empty_catalog" {
  command = plan

  variables {
    states       = []
    states_dirs  = ["../tests/states"]
    catalog_dirs = []
  }

  assert {
    condition     = length(output.available_states) == 0
    error_message = "Empty catalog_dirs should give an empty catalog"
  }
}
