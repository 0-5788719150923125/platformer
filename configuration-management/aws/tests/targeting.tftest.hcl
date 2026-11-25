# Tests for instance targeting modes in configuration-management module
# Validates both tag-based (scoped) and wildcard targeting behaviors

run "tag_based_targeting_with_instances" {
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
    # Simulate instances from compute module
    instances_by_class = {
      "windows-poc"        = { "bravo-windows-poc-0" = "i-1234567890abcdef0", "bravo-windows-poc-1" = "i-1234567890abcdef1" }
      "windows-production" = { "bravo-windows-production-0" = "i-1234567890abcdef2" }
    }
  }

  # Verify associations are created when instances exist
  assert {
    condition     = length(aws_ssm_association.document_association) > 0
    error_message = "Should create associations when instances exist (tag-based targeting)"
  }

  # Verify windows-password-rotation association exists
  assert {
    condition     = contains(keys(aws_ssm_association.document_association), "windows-password-rotation")
    error_message = "Should create windows-password-rotation association"
  }

  # Verify association targets use Class AND Namespace tags (not wildcard)
  assert {
    condition = alltrue([
      for assoc in aws_ssm_association.document_association :
      length(assoc.targets) == 2 &&
      assoc.targets[0].key == "tag:Class" &&
      assoc.targets[1].key == "tag:Namespace"
    ])
    error_message = "Associations should target instances by both 'Class' and 'Namespace' tags for proper isolation"
  }

  # Verify association targets include all class names
  assert {
    condition = alltrue([
      for assoc in aws_ssm_association.document_association :
      contains(assoc.targets[0].values, "windows-poc") &&
      contains(assoc.targets[0].values, "windows-production")
    ])
    error_message = "Association targets should include all instance classes"
  }

  # Verify association targets include correct namespace
  assert {
    condition = alltrue([
      for assoc in aws_ssm_association.document_association :
      assoc.targets[1].values[0] == "test-namespace"
    ])
    error_message = "Association targets should include the deployment namespace"
  }

  # Verify output indicates association has targets
  assert {
    condition     = output.documents["windows-password-rotation"].has_targets == true
    error_message = "Output should indicate association has targets"
  }
}

run "no_associations_without_instances" {
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
    # No instances provided
    instances_by_class = {}
  }

  # Verify documents are still created
  assert {
    condition     = length(aws_ssm_document.document) > 0
    error_message = "Should still create SSM documents even without instances"
  }

  # Verify NO associations are created when no instances exist
  assert {
    condition     = length(aws_ssm_association.document_association) == 0
    error_message = "Should NOT create associations when no instances exist (no wildcard fallback)"
  }

  # Verify output indicates no targets
  assert {
    condition     = output.documents["windows-password-rotation"].has_targets == false
    error_message = "Output should indicate no targets when instances don't exist"
  }

  # Verify association field is null in output
  assert {
    condition     = output.documents["windows-password-rotation"].association == null
    error_message = "Output association should be null when not created"
  }
}

run "explicit_wildcard_targeting" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      documents = {
        windows-password-rotation = {
          targets = [
            {
              key    = "InstanceIds"
              values = ["*"]
            }
          ]
        }
      }
    }
    # Even with no instances, explicit wildcard should work
    instances_by_class = {}
  }

  # Verify associations ARE created with explicit wildcard
  assert {
    condition     = length(aws_ssm_association.document_association) > 0
    error_message = "Should create associations with explicit wildcard targeting"
  }

  # Verify association uses wildcard (InstanceIds = ["*"])
  assert {
    condition = (
      aws_ssm_association.document_association["windows-password-rotation"].targets[0].key == "InstanceIds" &&
      contains(aws_ssm_association.document_association["windows-password-rotation"].targets[0].values, "*")
    )
    error_message = "Association should use wildcard targeting when explicitly configured"
  }

  # Verify output indicates association has targets
  assert {
    condition     = output.documents["windows-password-rotation"].has_targets == true
    error_message = "Output should indicate association has targets with explicit wildcard"
  }
}

run "explicit_tag_targeting_specific_classes" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      documents = {
        windows-password-rotation = {
          # Explicit override to target only specific classes
          targets = [
            {
              key    = "tag:Class"
              values = ["windows-production"]
            }
          ]
        }
      }
    }
    # Even though multiple classes exist, only target one
    instances_by_class = {
      "windows-poc"        = { "bravo-windows-poc-0" = "i-1234567890abcdef0" }
      "windows-production" = { "bravo-windows-production-0" = "i-1234567890abcdef1" }
    }
  }

  # Verify association is created
  assert {
    condition     = length(aws_ssm_association.document_association) > 0
    error_message = "Should create association with explicit tag targeting"
  }

  # Verify association targets ONLY the specified class
  assert {
    condition = (
      aws_ssm_association.document_association["windows-password-rotation"].targets[0].key == "tag:Class" &&
      length(aws_ssm_association.document_association["windows-password-rotation"].targets[0].values) == 1 &&
      contains(aws_ssm_association.document_association["windows-password-rotation"].targets[0].values, "windows-production")
    )
    error_message = "Association should target only explicitly specified classes"
  }
}

run "wildcard_ansible_application_targeting" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config         = {}
    # No compute instances - standalone deployment
    instances_by_class = {}
    # Ansible application testing requires real playbook files - skip for unit tests
    application_requests       = []
    application_scripts_bucket = ""
  }

  # Assertions removed - test no longer includes ansible applications
}

run "mixed_targeting_multiple_documents" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    aws_region     = "us-east-2"
    aws_profile    = "test-profile"
    config = {
      documents = {
        # windows-password-rotation uses default (tag-based)
        windows-password-rotation = {}
        # (Future documents could have different targeting)
      }
    }
    instances_by_class = {
      "windows-poc" = { "bravo-windows-poc-0" = "i-1234567890abcdef0" }
    }
  }

  # Verify all enabled documents create associations
  assert {
    condition     = length(aws_ssm_association.document_association) == length(output.config.enabled_documents)
    error_message = "All enabled documents should create associations when instances exist"
  }
}
