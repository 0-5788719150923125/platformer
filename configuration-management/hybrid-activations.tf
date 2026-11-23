# Hybrid Activation Resources for Non-AWS Machines
# Extends configuration-management module to support WSL, on-premises servers, and other non-AWS machines
# via AWS Systems Manager hybrid activations

locals {
  # Extract hybrid activation config from state fragment
  hybrid_activations_enabled = length(var.config.hybrid_activations) > 0
  hybrid_activations         = var.config.hybrid_activations

  # For each activation, collect the SSM resource tags that maintenance windows
  # select on, by matching hybrid_targeting.tag_value to the activation key.
  # Convention: name the activation the same as the window's tag_value
  # (e.g. activation "oci-ubuntu" <-> tag_value "oci-ubuntu").
  #
  # These go on the activation itself: SSM copies activation tags onto every
  # managed instance registered with it. ssm-setup-cli has no -tags flag for
  # on-prem registration (only in Greengrass mode), so this is the only way to
  # tag hosts at registration time.
  hybrid_tags_by_activation = {
    for activation_key in keys(local.hybrid_activations) :
    activation_key => merge([
      for window in values(local.maintenance_windows) :
      { (window.hybrid_targeting.tag_key) = window.hybrid_targeting.tag_value }
      if window.hybrid_targeting != null && window.hybrid_targeting.tag_value == activation_key
    ]...)
  }

  # Register command per activation. Tags come from the activation (see above).
  activation_register_command = {
    for key, activation in aws_ssm_activation.activation :
    key => format(
      "sudo /tmp/ssm/ssm-setup-cli -register -activation-code '%s' -activation-id '%s' -region '%s'",
      activation.activation_code,
      activation.id,
      data.aws_region.current.region
    )
  }
}

# Hybrid Activation Resource
# Creates activation credentials for registering non-AWS machines with SSM
# Registration command: sudo /tmp/ssm/ssm-setup-cli -register -activation-code "<code>" -activation-id "<id>" -region "<region>"
resource "aws_ssm_activation" "activation" {
  for_each = local.hybrid_activations

  # Namespace isolation: activation name includes namespace to prevent conflicts
  name        = "${each.key}-${var.namespace}"
  description = each.value.description

  # IAM role for registered instances (created in iam.tf)
  iam_role = var.access_iam_role_names["configuration-management-hybrid-instance"]

  # Registration limits and expiration
  registration_limit = each.value.registration_limit
  expiration_date    = timeadd(timestamp(), "${each.value.expiration_days * 24}h")

  # Tags: Class tag for consistency with compute module; provider default_tags
  # (ManagedBy, Project, Owner) are applied automatically. All of these are
  # copied onto every instance registered with this activation, including the
  # patch-targeting tag (e.g. PatchGroup) of any maintenance window aimed at it.
  tags = merge(local.hybrid_tags_by_activation[each.key], {
    Name  = "${each.key}-${var.namespace}"
    Class = each.key # Same pattern as compute instances (Class = instance class)
  })

  # Prevent drift on re-apply (expiration_date uses timestamp())
  lifecycle {
    ignore_changes = [expiration_date]
  }
}
