# Terraform tests for Legacy Atlantis deployment
# Tests basic configuration validation without actually creating resources

# Mock providers to avoid needing real AWS credentials
mock_provider "aws" {
  alias = "prod"
}

# Override the atlantis_secrets data source with mock data
override_data {
  target = data.aws_secretsmanager_secret_version.atlantis_secrets
  values = {
    secret_string = jsonencode({
      github_app_key        = "-----BEGIN RSA PRIVATE KEY-----\nMOCK_KEY\n-----END RSA PRIVATE KEY-----"
      github_webhook_secret = "mock-webhook-secret"
    })
  }
}

run "validate_configuration" {
  command = plan

  variables {
    namespace      = "test"
    aws_account_id = "123456789012"
    config = {
      instance_type           = "m6i.2xlarge"
      root_volume_size        = 40
      enable_public_ip        = true
      atlantis_repo_allowlist = ["github.com/acme-org/infra-terraform"]
      atlantis_port           = 80
      enable_ssh              = false
    }
  }

  # Verify instance configuration
  assert {
    condition     = aws_instance.atlantis.instance_type == "m6i.2xlarge"
    error_message = "Instance type should be m6i.2xlarge"
  }

  assert {
    condition     = aws_instance.atlantis.associate_public_ip_address == true
    error_message = "Public IP should be enabled for testing"
  }

  # Verify IAM instance profile is created
  assert {
    condition     = aws_iam_instance_profile.atlantis_instance.name != ""
    error_message = "IAM instance profile should be created"
  }

  # Verify security group is created
  assert {
    condition     = aws_security_group.atlantis_instance.name == "atlantis-legacy-test"
    error_message = "Security group name should match namespace"
  }

  # Verify web password is generated
  assert {
    condition     = random_password.atlantis_web_password.length == 32
    error_message = "Web password should be 32 characters"
  }

  # Verify locals are properly set
  assert {
    condition     = local.atlantis_web_username == "admin"
    error_message = "Default web username should be 'admin'"
  }
}

run "validate_variables" {
  command = plan

  variables {
    namespace      = "prod"
    aws_account_id = "111111111111"
  }

  # Verify default values are applied
  assert {
    condition     = var.config.instance_type == "m6i.2xlarge"
    error_message = "Default instance type should be m6i.2xlarge"
  }

  assert {
    condition     = var.config.atlantis_port == 80
    error_message = "Default Atlantis port should be 80"
  }

  assert {
    condition     = length(var.config.atlantis_repo_allowlist) == 1
    error_message = "Default repo allowlist should have one entry"
  }
}

run "validate_namespace_in_tags" {
  command = plan

  variables {
    namespace      = "staging"
    aws_account_id = "123456789012"
  }

  # Verify namespace is used in resource naming
  assert {
    condition     = aws_instance.atlantis.tags["Namespace"] == "staging"
    error_message = "Instance should be tagged with namespace"
  }

  assert {
    condition     = aws_security_group.atlantis_instance.name == "atlantis-legacy-staging"
    error_message = "Security group should include namespace in name"
  }
}
