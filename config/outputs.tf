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

output "merged_state" {
  description = "Complete merged state configuration (includes all top-level keys, not just services) - for debugging"
  value       = local.merged_state
}
