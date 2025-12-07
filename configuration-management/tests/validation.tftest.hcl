# Module-specific validation tests for configuration-management
# These test the module in isolation

run "default_values" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      documents = {
        windows-password-rotation = {
          enabled = true
        }
      }
    }
    # Provide instances so associations are created (new default behavior)
    instances_by_class = {
      "test-class" = { "test-instance-0" = "i-1234567890abcdef0" }
    }
  }

  # Verify default schedule is used
  assert {
    condition     = length([for doc in output.documents : doc if doc.schedule == "rate(30 minutes)"]) > 0
    error_message = "Should use default schedule 'rate(30 minutes)'"
  }

  # Verify default parameter store prefix
  assert {
    condition     = output.config.parameter_store_prefix == "/password-rotation"
    error_message = "Should use default parameter store prefix"
  }

  # Verify documents are discovered and created
  assert {
    condition     = length(output.config.enabled_documents) > 0
    error_message = "Should have at least one enabled document"
  }

  # Verify windows-password-rotation document exists
  assert {
    condition     = contains(output.config.enabled_documents, "windows-password-rotation")
    error_message = "Should include windows-password-rotation document"
  }

  # Verify SSM documents are created
  assert {
    condition     = length(aws_ssm_document.document) > 0
    error_message = "Should create at least one SSM document"
  }

  # Verify IAM policies are created for documents with .iam.json files
  assert {
    condition     = length(aws_iam_role_policy.document_policy) > 0
    error_message = "Should create at least one IAM policy"
  }

  # Verify windows-password-rotation has an IAM policy
  assert {
    condition     = contains(keys(aws_iam_role_policy.document_policy), "windows-password-rotation")
    error_message = "Should create IAM policy for windows-password-rotation"
  }

  # Verify associations are created when instances exist
  assert {
    condition     = length(aws_ssm_association.document_association) > 0
    error_message = "Should create at least one association when instances exist"
  }

  # Verify associations count in config output
  assert {
    condition     = output.config.associations > 0
    error_message = "Should report associations in config output"
  }
}

run "valid_schedule_expression" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      schedule_expression = "cron(0 2 ? * SUN *)"
      documents = {
        windows-password-rotation = {
          enabled = true
        }
      }
    }
  }

  # Verify the schedule is applied to documents
  assert {
    condition     = length([for doc in output.documents : doc if doc.schedule == "cron(0 2 ? * SUN *)"]) > 0
    error_message = "Module should accept and apply valid schedule expression"
  }
}

run "per_document_configuration" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      documents = {
        windows-password-rotation = {
          enabled             = true
          schedule_expression = "cron(0 2 ? * SUN#3 *)"
        }
      }
    }
  }

  # Verify document-specific config is respected
  assert {
    condition     = contains(output.config.enabled_documents, "windows-password-rotation")
    error_message = "windows-password-rotation should be enabled"
  }

  # Verify document-specific schedule override
  assert {
    condition     = output.documents["windows-password-rotation"].schedule == "cron(0 2 ? * SUN#3 *)"
    error_message = "windows-password-rotation should use custom schedule"
  }
}

run "disable_document" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      documents = {
        windows-password-rotation = {
          enabled = false
        }
      }
    }
  }

  # Verify disabled document is not created
  assert {
    condition     = !contains(output.config.enabled_documents, "windows-password-rotation")
    error_message = "windows-password-rotation should be disabled"
  }

  # Verify no documents or associations are created when all are disabled
  assert {
    condition     = length(aws_ssm_document.document) == 0
    error_message = "Should not create any SSM documents when all are disabled"
  }

  assert {
    condition     = length(aws_ssm_association.document_association) == 0
    error_message = "Should not create any associations when all are disabled"
  }

  assert {
    condition     = length(aws_iam_role_policy.document_policy) == 0
    error_message = "Should not create any IAM policies when all are disabled"
  }
}
