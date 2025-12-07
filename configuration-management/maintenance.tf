# Maintenance Windows - Define when patching occurs
# Targets and tasks are created in root main.tf (orchestration layer)

locals {
  # Filter to only enabled maintenance windows
  # maintenance_windows is now a map (window_name => window_config)
  maintenance_windows = local.patch_enabled ? {
    for name, window in var.config.patch_management.maintenance_windows :
    name => window
    if window.enabled
  } : {}
}

# Maintenance Windows - Define when patching occurs
resource "aws_ssm_maintenance_window" "window" {
  for_each = local.maintenance_windows

  name                       = "${each.key}-${var.namespace}"
  description                = "Maintenance window ${each.key} for baseline ${each.value.baseline}"
  schedule                   = each.value.schedule
  duration                   = each.value.duration
  cutoff                     = each.value.cutoff
  enabled                    = true
  allow_unassociated_targets = false

  tags = {
    Name      = "${each.key}-${var.namespace}"
    Namespace = var.namespace
    Baseline  = each.value.baseline
  }
}

# NOTE: Targets and tasks are created in root main.tf (orchestration layer)
# This allows explicit wiring of compute instances to maintenance windows
# without creating circular dependencies between modules
