# Patch Management Orchestration
# Wires compute instances to maintenance windows using class-based targeting
# This uses dependency inversion: compute module provides instances_by_class via variable

locals {
  # Convert patch_target_requests list to map for easier lookup
  patch_target_map = {
    for request in flatten([
      for window_name, window in aws_ssm_maintenance_window.window : [
        {
          window_id         = window.id
          window_name       = window_name
          baseline_name     = local.maintenance_windows[window_name].baseline
          baseline_id       = aws_ssm_patch_baseline.baseline[local.maintenance_windows[window_name].baseline].id
          target_classes    = local.baselines[local.maintenance_windows[window_name].baseline].classes
          service_role_arn  = var.access_iam_role_arns["configuration-management-maintenance-window"]
          target_tags       = local.maintenance_windows[window_name].target_tags
          dynamic_targeting = local.maintenance_windows[window_name].dynamic_targeting
          max_concurrency   = local.maintenance_windows[window_name].max_concurrency
          max_errors        = local.maintenance_windows[window_name].max_errors
          # Resource group key (for dynamic targeting)
          # Generate long key, then hash it to match dynamic-targeting.tf key format
          resource_group_key_long = local.maintenance_windows[window_name].dynamic_targeting != null ? (
            "${local.maintenance_windows[window_name].baseline}-${lower(replace(local.maintenance_windows[window_name].dynamic_targeting.platform_name, " ", ""))}-${local.maintenance_windows[window_name].dynamic_targeting.platform_version}"
          ) : null
          # Hash the long key to get the actual key used by resources (matches dynamic_targeting_key_map)
          resource_group_key = local.maintenance_windows[window_name].dynamic_targeting != null ? (
            substr(sha256("${local.maintenance_windows[window_name].baseline}-${lower(replace(local.maintenance_windows[window_name].dynamic_targeting.platform_name, " ", ""))}-${local.maintenance_windows[window_name].dynamic_targeting.platform_version}"), 0, 12)
          ) : null
        }
      ]
    ]) :
    request.window_name => request
  }
}

# Maintenance Window Targets
# Wires compute instances to maintenance windows using patch group targeting
resource "aws_ssm_maintenance_window_target" "patch" {
  # Only create if patch management enabled
  for_each = local.patch_enabled ? local.patch_target_map : {}

  window_id   = each.value.window_id
  name        = "${each.key}-targets-${var.namespace}"
  description = "Patch targets for ${each.key} baseline: ${each.value.baseline_name}"
  # Resource type depends on targeting method:
  # - RESOURCE_GROUP for dynamic targeting (Lambda + Resource Groups)
  # - INSTANCE for tag-based targeting (Patch Group tags or arbitrary tags)
  resource_type = local.patch_target_map[each.key].dynamic_targeting != null ? "RESOURCE_GROUP" : "INSTANCE"

  # Dynamic targeting: Resource Group (Lambda tags instances, Resource Group auto-populates)
  # Lambda queries SSM inventory and applies tags based on PlatformName/PlatformVersion
  # Resource Group uses native AWS tag query to auto-populate members
  # Scales to thousands of instances (no 50-instance limit like direct InstanceIds targeting)
  dynamic "targets" {
    for_each = local.patch_target_map[each.key].dynamic_targeting != null ? [1] : []
    content {
      key    = "resource-groups:Name"
      values = ["ssm-patch-${each.value.resource_group_key}-${var.namespace}"]
    }
  }

  # Tag-based targeting: Patch Group (namespaced)
  # Used when classes are specified (traditional approach)
  dynamic "targets" {
    for_each = local.patch_target_map[each.key].dynamic_targeting == null && length(each.value.target_classes) > 0 ? each.value.target_classes : []
    content {
      key    = "tag:Patch Group"
      values = ["${targets.value}-${var.namespace}"]
    }
  }

  # Tag-based targeting: Arbitrary organizational tags (fallback)
  # Used for wildcard targeting when dynamic_targeting is not available
  dynamic "targets" {
    for_each = local.patch_target_map[each.key].dynamic_targeting == null && local.patch_target_map[each.key].target_tags != null ? local.patch_target_map[each.key].target_tags : {}
    content {
      key    = "tag:${targets.key}"
      values = targets.value
    }
  }
}

# Maintenance Window Tasks
# Execute AWS-RunPatchBaselineWithHooks on targeted instances
resource "aws_ssm_maintenance_window_task" "patch" {
  for_each = aws_ssm_maintenance_window_target.patch

  window_id        = local.patch_target_map[each.key].window_id
  name             = "${each.key}-patch-task-${var.namespace}"
  description      = "Run patch baseline ${local.patch_target_map[each.key].baseline_name} on instances"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaselineWithHooks"
  priority         = 1
  service_role_arn = local.patch_target_map[each.key].service_role_arn
  max_concurrency  = local.patch_target_map[each.key].max_concurrency
  max_errors       = local.patch_target_map[each.key].max_errors

  targets {
    key    = "WindowTargetIds"
    values = [each.value.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      # Parameters for AWS-RunPatchBaselineWithHooks document
      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }

      # Universal pre-install safety hooks (Linux only)
      # Detects services (Redis, PostgreSQL, etc.) and performs appropriate safety checks
      # No-op if service not installed - no tags or configuration required
      parameter {
        name   = "PreInstallHookDocName"
        values = local.hooks_enabled ? [aws_ssm_document.universal_preinstall_linux[0].name] : ["AWS-Noop"]
      }

      # Universal post-install validation hooks (Linux only)
      # Ensures services are healthy after installation/reboot
      # No-op if service not installed - no tags or configuration required
      parameter {
        name   = "PostInstallHookDocName"
        values = local.hooks_enabled ? [aws_ssm_document.universal_postinstall_linux[0].name] : ["AWS-Noop"]
      }

      timeout_seconds = 3600 # 1 hour timeout per instance
    }
  }
}
