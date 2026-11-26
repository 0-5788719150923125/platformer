output "service_configs" {
  description = "Final resolved service configurations (fragments merged with union mode for list deduplication)"
  value       = local.final_service_configs
}

output "matrix_configs" {
  description = "Final resolved matrix configurations (regions, tenants, and future targeting dimensions)"
  value       = local.final_matrix_configs
}

output "loaded_fragments" {
  description = "List of fragments that were loaded"
  value       = var.fragments
}

output "fragment_files" {
  description = "Resolved file path for each selected fragment (name => path), after search-order precedence"
  value       = local.fragment_files
}

output "available_fragments" {
  description = "Every fragment found in catalog_dirs (name => path), first match wins. For catalogs, not just the selected fragments."
  value       = local.available_fragments
}

output "merged" {
  description = "Complete merged configuration (includes all top-level keys, not just services) - for debugging"
  value       = local.merged
}
