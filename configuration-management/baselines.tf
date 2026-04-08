# Patch Baselines - Define which patches are approved for different OS types
# Auto-enables when baselines or maintenance_windows are provided
# Baselines map to compute classes via the 'classes' attribute

locals {
  # Auto-enable patch management if baselines or maintenance_windows are provided
  patch_enabled = (
    length(var.config.patch_management.baselines) > 0 ||
    length(var.config.patch_management.maintenance_windows) > 0
  )

  # Normalize baselines config
  baselines = local.patch_enabled ? var.config.patch_management.baselines : {}
}

# Patch Baselines - Define which patches are approved
resource "aws_ssm_patch_baseline" "baseline" {
  for_each = local.baselines

  name                              = "${each.key}-${var.namespace}"
  description                       = "Patch baseline ${each.key} for classes: ${join(", ", each.value.classes)}"
  operating_system                  = each.value.operating_system
  approved_patches_compliance_level = each.value.approved_patches_compliance_level

  # Optional: Explicit approved patches
  approved_patches = each.value.approved_patches

  # Optional: Explicit rejected patches
  rejected_patches = each.value.rejected_patches

  # Approval rules with filters
  dynamic "approval_rule" {
    for_each = each.value.approval_rules
    content {
      approve_after_days  = approval_rule.value.approve_after_days
      compliance_level    = approval_rule.value.compliance_level
      enable_non_security = approval_rule.value.enable_non_security

      # Patch filters (classification, severity, etc.)
      dynamic "patch_filter" {
        for_each = length(approval_rule.value.patch_filter.classification) > 0 ? [1] : []
        content {
          key    = "CLASSIFICATION"
          values = approval_rule.value.patch_filter.classification
        }
      }

      dynamic "patch_filter" {
        for_each = length(approval_rule.value.patch_filter.severity) > 0 ? [1] : []
        content {
          # MSRC_SEVERITY is Windows-specific, SEVERITY is for Linux distros
          key    = each.value.operating_system == "WINDOWS" ? "MSRC_SEVERITY" : "SEVERITY"
          values = approval_rule.value.patch_filter.severity
        }
      }

      # Ubuntu-specific filters
      dynamic "patch_filter" {
        for_each = length(approval_rule.value.patch_filter.priority) > 0 ? [1] : []
        content {
          key    = "PRIORITY"
          values = approval_rule.value.patch_filter.priority
        }
      }

      dynamic "patch_filter" {
        for_each = length(approval_rule.value.patch_filter.section) > 0 ? [1] : []
        content {
          key    = "SECTION"
          values = approval_rule.value.patch_filter.section
        }
      }
    }
  }

  tags = {
    Name      = "${each.key}-${var.namespace}"
    Namespace = var.namespace
    Classes   = join(",", each.value.classes)
  }
}

# Patch Groups - Link baselines to compute classes
# Each class name becomes a patch group (AWS SSM concept) matching the instance's Patch Group tag
# Patch groups are namespaced to avoid conflicts in multi-workspace/multi-deployment scenarios
# NOTE: If baseline.classes is empty, no patch groups are created (wildcard targeting via OS filters only)
locals {
  # Flatten baselines × classes into patch group associations
  # Skip baselines with empty classes (wildcard targeting)
  patch_group_associations = flatten([
    for baseline_name, baseline in local.baselines : [
      for class_name in baseline.classes : {
        baseline_id   = aws_ssm_patch_baseline.baseline[baseline_name].id
        baseline_name = baseline_name
        class_name    = class_name
        patch_group   = "${class_name}-${var.namespace}" # Namespace patch groups to prevent conflicts
      }
    ] if length(baseline.classes) > 0
  ])
}

resource "aws_ssm_patch_group" "baseline_class" {
  for_each = {
    for assoc in local.patch_group_associations :
    "${assoc.baseline_name}-${assoc.class_name}" => assoc
  }

  baseline_id = each.value.baseline_id
  patch_group = each.value.patch_group
}

# Static patch group tagging  -  apply Patch Group tag to instances in statically-targeted classes
# Dynamic targeting (baselines with empty classes) is handled by the dynamic targeting Lambda
# Uses stable instance keys (e.g., "bravo-rocky-linux-0") for for_each to avoid plan-time errors
# when instance IDs are unknown (e.g., during ImageBuilder AMI rebuilds)
locals {
  static_patch_group_tags = merge([
    for assoc in local.patch_group_associations : {
      for instance_key, instance_id in lookup(var.instances_by_class, assoc.class_name, {}) :
      "${assoc.baseline_name}-${instance_key}" => {
        instance_id = instance_id
        patch_group = assoc.patch_group
      }
    }
  ]...)
}

resource "aws_ec2_tag" "patch_group" {
  for_each = local.static_patch_group_tags

  resource_id = each.value.instance_id
  key         = "Patch Group"
  value       = each.value.patch_group
}
