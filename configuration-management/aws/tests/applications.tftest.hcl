# SSM application deployments (ssm and compose requests): one document per
# request with the script embedded, its association's targets, and teardown.
# Offline: the AWS provider is mocked.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
}

variables {
  namespace      = "test"
  aws_account_id = "123456789012"
  aws_region     = "us-east-2"
  aws_profile    = "test-profile"
  config         = {}

  application_requests = [
    {
      class              = "src-docker-1"
      type               = "compose"
      script             = "compose-stack.sh"
      script_source_path = "../../applications/scripts/compose-stack.sh"
      params             = { STACK_NAME = "src", STACK_PORTS = "51000-51999/udp", NOTE = "it's quoted" }
      environment        = { TRACKER_HOST = "59.example.org", PEER_SOURCES = "https://github.com/a/b,https://gitlab.com/c/d", PRICE = "$5" }
      teardown           = true
      targeting_mode     = "instance"
      instance_id        = "mi-0000000000000000a"
    },
    {
      class              = "web"
      tenant             = "alpha"
      type               = "ssm"
      script             = "install-redis.sh"
      script_source_path = "../../applications/scripts/install-redis.sh"
      target_tag_key     = "Class"
      target_tag_value   = "web"
      targeting_mode     = "compute"
    },
    {
      class              = "agent"
      type               = "ssm"
      script             = "install-redis.sh"
      script_source_path = "../../applications/scripts/install-redis.sh"
      targeting_mode     = "wildcard"
    },
    {
      class              = "tagged"
      type               = "ssm"
      script             = "install-redis.sh"
      script_source_path = "../../applications/scripts/install-redis.sh"
      targeting_mode     = "tags"
      targets            = [{ key = "tag:Class", values = ["oci-ubuntu"] }]
    },
  ]
}

run "documents_and_associations" {
  command = plan

  assert {
    condition     = toset(keys(aws_ssm_document.applications)) == toset(["src-docker-1", "web-alpha-install-redis", "agent-install-redis", "tagged-install-redis"])
    error_message = "One document per ssm/compose request, keyed by class (+ tenant + script for ssm)"
  }

  assert {
    condition     = aws_ssm_document.applications["src-docker-1"].name == "app-src-docker-1-test"
    error_message = "Documents are named app-<key>-<namespace>"
  }

  # The script, parameters and environment are embedded base64-encoded.
  assert {
    condition = strcontains(
      join("\n", jsondecode(aws_ssm_document.applications["src-docker-1"].content).mainSteps[0].inputs.runCommand),
      base64encode(file("../../applications/scripts/compose-stack.sh"))
    )
    error_message = "The document should embed the script"
  }

  assert {
    condition = strcontains(
      join("\n", jsondecode(aws_ssm_document.applications["src-docker-1"].content).mainSteps[0].inputs.runCommand),
      base64encode("PEER_SOURCES='https://github.com/a/b,https://gitlab.com/c/d'\nPRICE='$5'\nTRACKER_HOST='59.example.org'\n")
    )
    error_message = "The environment file should be KEY='value' lines, sorted, values literal"
  }

  assert {
    condition = strcontains(
      join("\n", jsondecode(aws_ssm_document.applications["src-docker-1"].content).mainSteps[0].inputs.runCommand),
      base64encode("NOTE='it'\\''s quoted'\nSTACK_NAME='src'\nSTACK_PORTS='51000-51999/udp'\n")
    )
    error_message = "Parameters should be sh assignments with single quotes escaped"
  }

  assert {
    condition     = jsondecode(aws_ssm_document.applications["src-docker-1"].content).parameters.action.allowedValues == ["up", "down"]
    error_message = "The action parameter only allows up and down"
  }

  # Nothing user-supplied appears in clear text, so no SSM {{ }} placeholders
  # but {{ action }} can occur.
  assert {
    condition     = length(regexall("\\{\\{", join("\n", jsondecode(aws_ssm_document.applications["src-docker-1"].content).mainSteps[0].inputs.runCommand))) == 1
    error_message = "Only the {{ action }} placeholder may appear in the commands"
  }

  # Targets by mode
  assert {
    condition = (
      length(aws_ssm_association.applications["src-docker-1"].targets) == 1 &&
      aws_ssm_association.applications["src-docker-1"].targets[0].key == "InstanceIds" &&
      aws_ssm_association.applications["src-docker-1"].targets[0].values == tolist(["mi-0000000000000000a"])
    )
    error_message = "instance mode targets the instance ID (EC2 or hybrid)"
  }

  assert {
    condition = (
      length(aws_ssm_association.applications["web-alpha-install-redis"].targets) == 2 &&
      aws_ssm_association.applications["web-alpha-install-redis"].targets[0].key == "tag:Class" &&
      aws_ssm_association.applications["web-alpha-install-redis"].targets[1].key == "tag:Tenant"
    )
    error_message = "compute mode targets Class AND Tenant"
  }

  assert {
    condition = (
      aws_ssm_association.applications["agent-install-redis"].targets[0].key == "InstanceIds" &&
      aws_ssm_association.applications["agent-install-redis"].targets[0].values == tolist(["*"])
    )
    error_message = "wildcard mode targets every instance"
  }

  assert {
    condition = (
      aws_ssm_association.applications["tagged-install-redis"].targets[0].key == "tag:Class" &&
      aws_ssm_association.applications["tagged-install-redis"].targets[0].values == tolist(["oci-ubuntu"])
    )
    error_message = "tags mode passes its targets through"
  }

  # Rollout and teardown
  assert {
    condition = (
      aws_ssm_association.applications["src-docker-1"].max_concurrency == "1" &&
      aws_ssm_association.applications["src-docker-1"].max_errors == "0"
    )
    error_message = "compose rolls out one host at a time and stops at the first failure"
  }

  assert {
    condition     = keys(terraform_data.application_teardown) == ["src-docker-1"]
    error_message = "Only teardown-enabled (compose) requests get a teardown resource"
  }

  assert {
    condition     = jsondecode(terraform_data.application_teardown["src-docker-1"].input.targets) == [{ Key = "InstanceIds", Values = ["mi-0000000000000000a"] }]
    error_message = "Teardown targets match the association's, in send-command form"
  }

  # No S3 for script applications
  assert {
    condition     = length(aws_s3_bucket_policy.application_scripts_access) == 0 && length(aws_iam_role_policy.application_scripts_access) == 0
    error_message = "ssm/compose requests need no scripts bucket policy or instance-role S3 access"
  }
}

run "environment_values_cannot_hold_quotes" {
  command = plan

  variables {
    application_requests = [
      {
        class              = "bad"
        type               = "compose"
        script             = "compose-stack.sh"
        script_source_path = "../../applications/scripts/compose-stack.sh"
        environment        = { GREETING = "it's" }
        targeting_mode     = "wildcard"
      },
    ]
  }

  expect_failures = [aws_ssm_document.applications]
}

run "environment_keys_must_be_names" {
  command = plan

  variables {
    application_requests = [
      {
        class              = "bad"
        type               = "compose"
        script             = "compose-stack.sh"
        script_source_path = "../../applications/scripts/compose-stack.sh"
        environment        = { "NOT A NAME" = "x" }
        targeting_mode     = "wildcard"
      },
    ]
  }

  expect_failures = [aws_ssm_document.applications]
}
