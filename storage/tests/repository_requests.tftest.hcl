# Test dependency inversion pattern for CodeCommit repositories

variables {
  aws_account_id = "123456789012"
}

# Test 1: Basic repository creation with dependency inversion pattern
run "repository_requests_basic" {
  command = plan

  variables {
    namespace = "test-namespace"

    repository_requests = [
      {
        purpose     = "archivist"
        description = "Git-based archive of scrubbed platformer codebase"
      }
    ]
  }

  # Verify repository is created with correct name
  assert {
    condition     = aws_codecommit_repository.requested["archivist"].repository_name == "archivist-test-namespace"
    error_message = "Repository name should follow purpose-namespace pattern"
  }

  # Verify description is set
  assert {
    condition     = aws_codecommit_repository.requested["archivist"].description == "Git-based archive of scrubbed platformer codebase"
    error_message = "Repository description should match request"
  }

  # Verify tags
  assert {
    condition     = aws_codecommit_repository.requested["archivist"].tags["Purpose"] == "archivist"
    error_message = "Repository should be tagged with purpose"
  }

  assert {
    condition     = aws_codecommit_repository.requested["archivist"].tags["Namespace"] == "test-namespace"
    error_message = "Repository should be tagged with namespace"
  }
}

# Test 2: Empty repository_requests (no repos created)
run "repository_requests_empty" {
  command = plan

  variables {
    namespace           = "test"
    repository_requests = []
  }

  # Verify no repositories are created
  assert {
    condition     = length(aws_codecommit_repository.requested) == 0
    error_message = "No repositories should be created when repository_requests is empty"
  }
}

# Test 3: Unique purpose validation (should fail)
run "repository_requests_unique_purpose_validation" {
  command = plan

  variables {
    namespace = "test"

    repository_requests = [
      { purpose = "repo", description = "Repo 1" },
      { purpose = "repo", description = "Repo 2" } # Duplicate purpose
    ]
  }

  expect_failures = [
    var.repository_requests
  ]
}

# Test 4: Type validation (should fail on unsupported type)
run "repository_requests_type_validation" {
  command = plan

  variables {
    namespace = "test"

    repository_requests = [
      {
        purpose     = "bad-repo"
        description = "Bad type"
        type        = "github"
      }
    ]
  }

  expect_failures = [
    var.repository_requests
  ]
}

# Test 5: Multiple repositories
run "repository_requests_multiple" {
  command = plan

  variables {
    namespace = "test"

    repository_requests = [
      {
        purpose     = "archivist"
        description = "Archive repository"
      },
      {
        purpose     = "config"
        description = "Config repository"
      }
    ]
  }

  # Verify all repositories are created
  assert {
    condition     = length(aws_codecommit_repository.requested) == 2
    error_message = "All requested repositories should be created"
  }

  # Verify names
  assert {
    condition     = aws_codecommit_repository.requested["archivist"].repository_name == "archivist-test"
    error_message = "First repository name should follow purpose-namespace pattern"
  }

  assert {
    condition     = aws_codecommit_repository.requested["config"].repository_name == "config-test"
    error_message = "Second repository name should follow purpose-namespace pattern"
  }
}

# Test 6: Repository with on_create_command (verify null_resource is created)
run "repository_requests_with_command" {
  command = plan

  variables {
    namespace   = "test"
    aws_profile = "test-profile"
    aws_region  = "us-east-2"

    repository_requests = [
      {
        purpose           = "archivist"
        description       = "Archive repository"
        on_create_command = "echo hello"
        commit_trigger    = "trigger-123"
      }
    ]
  }

  # Verify post-create commit null_resource is created
  assert {
    condition     = length(null_resource.post_create_commit) == 1
    error_message = "Post-create commit should be created when on_create_command is set"
  }

  # Verify set-default-branch null_resource is created
  assert {
    condition     = length(null_resource.set_default_branch) == 1
    error_message = "Set-default-branch should be created when on_create_command is set"
  }
}
