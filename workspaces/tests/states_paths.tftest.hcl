# Workspaces Module Tests - states_paths parsing
# Each run points the module at a fixture file instead of
# terraform.tfvars.<workspace>.

variables {
  default_aws_region   = "us-east-2"
  default_owner        = "Platform"
  default_states       = ["base-state"]
  default_states_paths = ["/base/path"]
}

run "parses_states_paths_and_ignores_comments" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/full.hcl"
  }

  assert {
    condition     = jsonencode(output.states_paths) == jsonencode(["~/configs/platformer", "/srv/states", "relative/dir"])
    error_message = "Expected the three listed paths in order, got: ${jsonencode(output.states_paths)}"
  }

  assert {
    condition     = jsonencode(output.states) == jsonencode(["alpha", "beta"])
    error_message = "states should still parse alongside states_paths, got: ${jsonencode(output.states)}"
  }
}

run "empty_list_clears_base_paths" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/paths-empty.hcl"
  }

  assert {
    condition     = jsonencode(output.states_paths) == jsonencode([])
    error_message = "states_paths = [] should override the base list, got: ${jsonencode(output.states_paths)}"
  }
}

run "states_paths_does_not_shadow_states" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/paths-only.hcl"
  }

  assert {
    condition     = jsonencode(output.states_paths) == jsonencode(["/home/me/states"])
    error_message = "Expected states_paths from the file, got: ${jsonencode(output.states_paths)}"
  }

  # The states regex must not match the "states_paths" key
  assert {
    condition     = jsonencode(output.states) == jsonencode(["base-state"])
    error_message = "states should fall back to default when only states_paths is set, got: ${jsonencode(output.states)}"
  }
}

run "falls_back_to_default_paths" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/no-paths.hcl"
  }

  assert {
    condition     = jsonencode(output.states_paths) == jsonencode(["/base/path"])
    error_message = "states_paths should fall back to default, got: ${jsonencode(output.states_paths)}"
  }

  assert {
    condition     = jsonencode(output.states) == jsonencode(["gamma"])
    error_message = "Expected states from the file, got: ${jsonencode(output.states)}"
  }
}

run "disabled_ignores_file" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/full.hcl"
    enabled             = false
  }

  assert {
    condition     = jsonencode(output.states_paths) == jsonencode(["/base/path"]) && jsonencode(output.states) == jsonencode(["base-state"])
    error_message = "enabled = false should return defaults"
  }
}
