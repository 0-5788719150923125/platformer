# Workspaces Module Tests - fragment_paths parsing
# Each run points the module at a fixture file instead of
# terraform.tfvars.<workspace>.

variables {
  default_aws_region     = "us-east-2"
  default_owner          = "Platform"
  default_fragments      = ["base-fragment"]
  default_fragment_paths = ["/base/path"]
}

run "parses_fragment_paths_and_ignores_comments" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/full.hcl"
  }

  assert {
    condition     = jsonencode(output.fragment_paths) == jsonencode(["~/configs/platformer", "/srv/fragments", "relative/dir"])
    error_message = "Expected the three listed paths in order, got: ${jsonencode(output.fragment_paths)}"
  }

  assert {
    condition     = jsonencode(output.fragments) == jsonencode(["alpha", "beta"])
    error_message = "fragments should still parse alongside fragment_paths, got: ${jsonencode(output.fragments)}"
  }
}

run "empty_list_clears_base_paths" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/paths-empty.hcl"
  }

  assert {
    condition     = jsonencode(output.fragment_paths) == jsonencode([])
    error_message = "fragment_paths = [] should override the base list, got: ${jsonencode(output.fragment_paths)}"
  }
}

run "fragment_paths_does_not_shadow_fragments" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/paths-only.hcl"
  }

  assert {
    condition     = jsonencode(output.fragment_paths) == jsonencode(["/home/me/fragments"])
    error_message = "Expected fragment_paths from the file, got: ${jsonencode(output.fragment_paths)}"
  }

  # The fragments regex must not match the "fragment_paths" key
  assert {
    condition     = jsonencode(output.fragments) == jsonencode(["base-fragment"])
    error_message = "fragments should fall back to default when only fragment_paths is set, got: ${jsonencode(output.fragments)}"
  }
}

run "falls_back_to_default_paths" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/no-paths.hcl"
  }

  assert {
    condition     = jsonencode(output.fragment_paths) == jsonencode(["/base/path"])
    error_message = "fragment_paths should fall back to default, got: ${jsonencode(output.fragment_paths)}"
  }

  assert {
    condition     = jsonencode(output.fragments) == jsonencode(["gamma"])
    error_message = "Expected fragments from the file, got: ${jsonencode(output.fragments)}"
  }
}

run "disabled_ignores_file" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/full.hcl"
    enabled             = false
  }

  assert {
    condition     = jsonencode(output.fragment_paths) == jsonencode(["/base/path"]) && jsonencode(output.fragments) == jsonencode(["base-fragment"])
    error_message = "enabled = false should return defaults"
  }
}

run "old_names_fail" {
  command = plan

  variables {
    workspace_file_path = "tests/fixtures/old-names.hcl"
  }

  expect_failures = [output.fragments]
}
