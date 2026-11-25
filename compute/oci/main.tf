# OCI Compute Adapter
#
# Runs generic instance classes (type = "instance", cloud = "oci") on Oracle
# Cloud. Wired into the compute module by scripts/providers.sh only in
# workspaces that declare oci_profile; inherits the root's default `oci`
# provider implicitly.
#
# Networking is referenced, not managed: instances join an existing subnet by
# OCID. Shared networks (e.g. one that also hosts instances outside Platformer)
# stay untouched.

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

# The subnet's compartment is the default home for its instances
data "oci_core_subnet" "this" {
  for_each  = toset([for key, instance in var.config : instance.settings.subnet_id])
  subnet_id = each.key
}

resource "oci_core_instance" "this" {
  for_each = var.config

  availability_domain = each.value.settings.availability_domain
  compartment_id      = coalesce(each.value.settings.compartment_id, data.oci_core_subnet.this[each.value.settings.subnet_id].compartment_id)
  shape               = each.value.settings.shape
  display_name        = each.key

  dynamic "shape_config" {
    for_each = each.value.settings.ocpus != null ? [1] : []
    content {
      ocpus         = each.value.settings.ocpus
      memory_in_gbs = each.value.settings.memory_in_gbs
    }
  }

  create_vnic_details {
    subnet_id        = each.value.settings.subnet_id
    assign_public_ip = tostring(each.value.settings.assign_public_ip)
  }

  source_details {
    source_type             = "image"
    source_id               = each.value.settings.image_id
    boot_volume_size_in_gbs = each.value.settings.boot_volume_size_in_gbs == null ? null : tostring(each.value.settings.boot_volume_size_in_gbs)
  }

  metadata = each.value.settings.ssh_authorized_keys == null ? {} : {
    ssh_authorized_keys = each.value.settings.ssh_authorized_keys
  }

  lifecycle {
    # Free tier capacity is scarce, and losing an instance can be permanent.
    # Destroying one must be a deliberate code change, never a side effect of a plan.
    prevent_destroy = true

    # Launch-time settings. Adopted instances keep their own values, and changing
    # these on a running instance would otherwise force a replacement. OCI also
    # adds its own defined tags (Oracle-Tags.CreatedBy/CreatedOn).
    ignore_changes = [
      display_name,
      metadata,
      source_details,
      create_vnic_details,
      defined_tags,
      freeform_tags,
    ]
  }
}
