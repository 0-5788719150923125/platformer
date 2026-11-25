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
