# Test suite for root-level variable validations
# Tests only root-level concerns, not module-specific logic

# Test: Valid AWS profile should pass
run "valid_aws_profile" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    fragments   = []
  }

  assert {
    condition     = var.aws_profile == "example-platform-dev"
    error_message = "AWS profile should be accepted when valid"
  }
}

# Test: Valid AWS profile with underscores should pass
run "valid_aws_profile_with_underscores" {
  command = plan

  variables {
    aws_profile = "example-account-uat"
    fragments   = []
  }

  assert {
    condition     = var.aws_profile == "example-account-uat"
    error_message = "AWS profile with underscores should be accepted"
  }
}

# Test: Invalid AWS profile with spaces should fail
run "invalid_aws_profile_with_spaces" {
  command = plan

  variables {
    aws_profile = "my profile"
    fragments   = []
  }

  expect_failures = [
    var.aws_profile,
  ]
}

# Test: Valid AWS region should pass
run "valid_aws_region" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    aws_region  = "us-west-2"
    fragments   = []
  }

  assert {
    condition     = var.aws_region == "us-west-2"
    error_message = "AWS region should be accepted when valid"
  }
}

# Test: Valid AWS region with different formats
run "valid_aws_region_formats" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    aws_region  = "ap-southeast-1"
    fragments   = []
  }

  assert {
    condition     = var.aws_region == "ap-southeast-1"
    error_message = "AWS region should accept various valid formats"
  }
}

# Test: Invalid AWS region format should fail
run "invalid_aws_region_format" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    aws_region  = "invalid-region"
    fragments   = []
  }

  expect_failures = [
    var.aws_region,
  ]
}

# Test: Invalid AWS region with uppercase should fail
run "invalid_aws_region_uppercase" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    aws_region  = "US-EAST-1"
    fragments   = []
  }

  expect_failures = [
    var.aws_region,
  ]
}

# Test: Invalid AWS region without number should fail
run "invalid_aws_region_no_number" {
  command = plan

  variables {
    aws_profile = "example-platform-dev"
    aws_region  = "us-east"
    fragments   = []
  }

  expect_failures = [
    var.aws_region,
  ]
}

run "old_states_variable_fails" {
  command = plan

  variables {
    fragments = []
    states    = ["praxis-src"]
  }

  expect_failures = [var.states]
}
