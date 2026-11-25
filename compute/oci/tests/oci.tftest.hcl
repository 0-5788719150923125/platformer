# OCI compute adapter (compute/oci/). Mock provider: no Oracle account needed.
# Plan only: the adapter's prevent_destroy would block the cleanup that follows
# an apply, which is exactly the protection it exists to give.

mock_provider "oci" {
  mock_data "oci_core_subnet" {
    defaults = {
      compartment_id = "ocid1.compartment.oc1..subnet-compartment"
    }
  }
}

variables {
  context = { namespace = "test" }
}

run "fixed_shape_launches_in_the_subnets_compartment" {
  command = plan

  variables {
    config = {
      "src-docker-0" = {
        tenant = "src"
        class  = "docker"
        index  = 0
        settings = {
          shape               = "VM.Standard.E2.1.Micro"
          image_id            = "ocid1.image.oc1..ubuntu"
          subnet_id           = "ocid1.subnet.oc1..shared"
          availability_domain = "pdyy:US-ASHBURN-AD-1"
        }
      }
    }
  }

  assert {
    condition     = oci_core_instance.this["src-docker-0"].shape == "VM.Standard.E2.1.Micro"
    error_message = "Shape should come from the class's oci settings"
  }
  assert {
    condition     = oci_core_instance.this["src-docker-0"].compartment_id == "ocid1.compartment.oc1..subnet-compartment"
    error_message = "Without compartment_id, instances should live in their subnet's compartment"
  }
  assert {
    condition     = oci_core_instance.this["src-docker-0"].create_vnic_details[0].assign_public_ip == "true"
    error_message = "assign_public_ip defaults to true and must be passed as the string the provider expects"
  }
  assert {
    condition     = oci_core_instance.this["src-docker-0"].source_details[0].source_id == "ocid1.image.oc1..ubuntu"
    error_message = "The launch image should come from image_id"
  }
  assert {
    condition     = oci_core_instance.this["src-docker-0"].display_name == "src-docker-0"
    error_message = "New instances are named by their key, like EC2 instances"
  }
  assert {
    condition     = length(oci_core_instance.this["src-docker-0"].shape_config) == 0
    error_message = "Fixed shapes must not set shape_config"
  }
  assert {
    condition     = output.instances["src-docker-0"].adopted == false
    error_message = "An instance without adopt_id is not adopted"
  }
}

run "flex_shape_explicit_compartment_and_launch_details" {
  command = plan

  variables {
    config = {
      "lab-flex-0" = {
        tenant   = "lab"
        class    = "flex"
        index    = 0
        adopt_id = "ocid1.instance.oc1..existing"
        settings = {
          shape                   = "VM.Standard.E4.Flex"
          ocpus                   = 2
          memory_in_gbs           = 12
          image_id                = "ocid1.image.oc1..ubuntu"
          subnet_id               = "ocid1.subnet.oc1..shared"
          availability_domain     = "pdyy:US-ASHBURN-AD-1"
          compartment_id          = "ocid1.compartment.oc1..explicit"
          assign_public_ip        = false
          ssh_authorized_keys     = "ssh-ed25519 AAAAC3Nza test@example"
          boot_volume_size_in_gbs = 100
        }
      }
    }
  }

  assert {
    condition     = oci_core_instance.this["lab-flex-0"].shape_config[0].ocpus == 2 && oci_core_instance.this["lab-flex-0"].shape_config[0].memory_in_gbs == 12
    error_message = "Flex shapes should get ocpus and memory_in_gbs"
  }
  assert {
    condition     = oci_core_instance.this["lab-flex-0"].compartment_id == "ocid1.compartment.oc1..explicit"
    error_message = "An explicit compartment_id wins over the subnet's"
  }
  assert {
    condition     = oci_core_instance.this["lab-flex-0"].create_vnic_details[0].assign_public_ip == "false"
    error_message = "assign_public_ip = false should reach the provider as \"false\""
  }
  assert {
    condition     = oci_core_instance.this["lab-flex-0"].metadata["ssh_authorized_keys"] == "ssh-ed25519 AAAAC3Nza test@example"
    error_message = "SSH keys should be installed through metadata"
  }
  assert {
    condition     = oci_core_instance.this["lab-flex-0"].source_details[0].boot_volume_size_in_gbs == "100"
    error_message = "Boot volume size should reach the provider as a string"
  }
  assert {
    condition     = output.instances["lab-flex-0"].adopted == true
    error_message = "An instance with adopt_id is reported as adopted"
  }
}

run "no_instances" {
  command = plan

  variables {
    config = {}
  }

  assert {
    condition     = length(oci_core_instance.this) == 0 && length(output.instances) == 0
    error_message = "Empty config should create nothing"
  }
}
