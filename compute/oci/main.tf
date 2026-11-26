# OCI Compute Adapter
#
# Runs generic instance classes (type = "instance", cloud = "oci") on Oracle
# Cloud. Called from compute/adapters.tf. Its provider is
# platformer.local/lazyprovider/oci (the lazy proxy), inherited from the root,
# which is only set up in workspaces that set oci_profile.
#
# Networking is referenced, not managed: instances join an existing subnet by
# OCID. Shared networks (e.g. one that also hosts instances outside Platformer)
# stay untouched.

terraform {
  required_providers {
    oci = {
      source = "platformer.local/lazyprovider/oci"
    }
  }
}

# The subnet's compartment is the default home for its instances
data "oci_core_subnet" "this" {
  for_each  = toset([for key, instance in var.config : instance.settings.subnet_id])
  subnet_id = each.key
}

# Classes with inbound rules get one network security group each, attached to
# their instances' primary VNICs. Not to the subnet: other machines may share it.
locals {
  instances_by_class = { for key, instance in var.config : instance.class => instance... }
  nsg_classes = {
    for class, instances in local.instances_by_class : class => instances[0].settings
    if length(instances[0].settings.ingress) > 0
  }
  nsg_rules = merge([
    for class, settings in local.nsg_classes : {
      for idx, rule in settings.ingress : "${class}-${idx}" => merge(rule, {
        class = class
        min   = tonumber(split("-", rule.ports)[0])
        max   = tonumber(element(split("-", rule.ports), length(split("-", rule.ports)) - 1))
      })
    }
  ]...)
}

resource "oci_core_network_security_group" "class" {
  for_each = local.nsg_classes

  compartment_id = coalesce(each.value.compartment_id, data.oci_core_subnet.this[each.value.subnet_id].compartment_id)
  vcn_id         = data.oci_core_subnet.this[each.value.subnet_id].vcn_id
  display_name   = "${each.key}-${var.context.namespace}"
}

resource "oci_core_network_security_group_security_rule" "ingress" {
  for_each = local.nsg_rules

  network_security_group_id = oci_core_network_security_group.class[each.value.class].id
  direction                 = "INGRESS"
  protocol                  = each.value.protocol == "udp" ? "17" : "6"
  source                    = each.value.source
  source_type               = "CIDR_BLOCK"
  description               = each.value.description

  dynamic "tcp_options" {
    for_each = each.value.protocol == "tcp" ? [1] : []
    content {
      destination_port_range {
        min = each.value.min
        max = each.value.max
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "udp" ? [1] : []
    content {
      destination_port_range {
        min = each.value.min
        max = each.value.max
      }
    }
  }
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
    nsg_ids          = contains(keys(local.nsg_classes), each.value.class) ? [oci_core_network_security_group.class[each.value.class].id] : []
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
    # adds its own defined tags (Oracle-Tags.CreatedBy/CreatedOn). The VNIC's
    # nsg_ids stays managed: security groups attach in place.
    ignore_changes = [
      display_name,
      metadata,
      source_details,
      defined_tags,
      freeform_tags,
      create_vnic_details[0].assign_ipv6ip,
      create_vnic_details[0].assign_private_dns_record,
      create_vnic_details[0].assign_public_ip,
      create_vnic_details[0].defined_tags,
      create_vnic_details[0].display_name,
      create_vnic_details[0].freeform_tags,
      create_vnic_details[0].hostname_label,
      create_vnic_details[0].private_ip,
      create_vnic_details[0].private_ip_id,
      create_vnic_details[0].security_attributes,
      create_vnic_details[0].skip_source_dest_check,
      create_vnic_details[0].subnet_cidr,
      create_vnic_details[0].subnet_id,
      create_vnic_details[0].vlan_id,
    ]
  }
}
