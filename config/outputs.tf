output "service_configs" {
  description = "Final resolved service configurations (states merged with union mode for list deduplication)"
  value       = local.final_service_configs
}

output "matrix_configs" {
  description = "Final resolved matrix configurations (regions, tenants, and future targeting dimensions)"
  value       = local.final_matrix_configs
}

output "loaded_states" {
  description = "List of state fragments that were loaded"
  value       = var.states
}

output "state_paths" {
  description = "Resolved file path for each selected state fragment (name => path), after search-order precedence"
  value       = local.state_paths
}

output "available_states" {
  description = "Every fragment found in catalog_dirs (name => path), first match wins. For catalogs, not just the selected states."
  value       = local.available_states
}

output "merged_state" {
  description = "Complete merged state configuration (includes all top-level keys, not just services) - for debugging"
  value       = local.merged_state
}
