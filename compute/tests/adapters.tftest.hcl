# Generic adapter layer (compute/adapters.tf): routing generic instance classes
# to clouds, adoption, and the checks that keep both from failing silently.
#
# Runs against the committed configuration, with no optional providers wired
# in (scripts/providers.sh in a workspace without them, e.g. default). The
# adapters themselves are tested in compute/aws/tests and compute/oci/tests.

mock_provider "aws" {}

variables {
  namespace         = "test-namespace"
  aws_account_id    = "123456789012"
  preflight_enabled = false
}

run "no_instance_classes" {
  command = plan

  variables {
    config = {}
  }

  assert {
    condition     = length(output.adapter_instances) == 0 && length(output.adoptions) == 0
    error_message = "Without generic instance classes there is nothing to route or adopt"
  }
}

run "instance_class_without_its_adapter_fails" {
  command = plan

  variables {
    tenants_by_class = { docker = ["src"] }
    config = {
      docker = {
        type  = "instance"
        cloud = "oci"
        oci = {
          shape               = "VM.Standard.E2.1.Micro"
          image_id            = "ocid1.image.oc1..ubuntu"
          subnet_id           = "ocid1.subnet.oc1..shared"
          availability_domain = "pdyy:US-ASHBURN-AD-1"
        }
      }
    }
  }

  # The oci adapter isn't wired in, so the plan must stop instead of quietly
  # dropping the class.
  expect_failures = [output.adapter_instances]
}

run "adoption_without_a_tenant_fails" {
  command = plan

  variables {
    tenants_by_class = { docker = [] } # e.g. a tenant missing from tenants/tenants.yaml
    config = {
      docker = {
        type  = "instance"
        cloud = "oci"
        adopt = ["ocid1.instance.oc1..existing"]
        oci = {
          shape               = "VM.Standard.E2.1.Micro"
          image_id            = "ocid1.image.oc1..ubuntu"
          subnet_id           = "ocid1.subnet.oc1..shared"
          availability_domain = "pdyy:US-ASHBURN-AD-1"
        }
      }
    }
  }

  # With no entitled tenant the class expands to nothing, so adoption would be
  # silently skipped. It must fail instead.
  expect_failures = [output.adapter_instances]
}

run "instance_class_needs_a_cloud" {
  command = plan

  variables {
    config = {
      docker = { type = "instance" }
    }
  }

  expect_failures = [var.config]
}

run "aws_instance_class_runs_on_the_ec2_path" {
  command = plan

  variables {
    tenants_by_class = { web = ["alpha"] }
    config = {
      web = {
        type  = "instance"
        cloud = "aws"
        count = 2
        aws = {
          ami_filter    = "al2023-ami-*-x86_64"
          instance_type = "t3.micro"
        }
      }
    }
  }

  assert {
    condition     = toset(keys(output.instances)) == toset(["alpha-web-0", "alpha-web-1"])
    error_message = "AWS instance classes expand like EC2 classes, with the same keys"
  }
  assert {
    condition     = output.instances["alpha-web-0"].instance_type == "t3.micro"
    error_message = "Settings under aws: should reach the instance"
  }
  assert {
    condition     = length(output.adapter_instances) == 0 && length(output.adoptions) == 0
    error_message = "AWS instances run on the EC2 path, not through the cloud adapters"
  }
}

run "aws_settings_win_over_top_level_ec2_fields" {
  command = plan

  variables {
    tenants_by_class = { web = ["alpha"] }
    config = {
      web = {
        type          = "instance"
        cloud         = "aws"
        instance_type = "t3.large" # top-level EC2 field, overridden below
        aws = {
          ami_filter    = "al2023-ami-*-x86_64"
          instance_type = "t3.micro"
        }
      }
    }
  }

  assert {
    condition     = output.instances["alpha-web-0"].instance_type == "t3.micro"
    error_message = "A value under aws: should win over the top-level field"
  }
}

run "adoption_on_aws_is_rejected" {
  command = plan

  variables {
    tenants_by_class = { web = ["alpha"] }
    config = {
      web = {
        type  = "instance"
        cloud = "aws"
        adopt = ["i-0123456789abcdef0"]
        aws   = { ami_filter = "al2023-ami-*-x86_64" }
      }
    }
  }

  expect_failures = [var.config]
}
