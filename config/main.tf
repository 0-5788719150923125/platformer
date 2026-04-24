# Config Module
# Resolves final service configuration by loading and deep-merging YAML state fragments
# Uses deepmerge provider for native type preservation and plan-time validation

locals {
  # Resolve each states_dirs entry: absolute paths are used verbatim,
  # relative paths are prefixed with path.module for backward compatibility
  # with Platformer's own usage (which passes e.g. "../states" to mean
  # "up one level from the config module").
  resolved_dirs = [
    for dir in var.states_dirs :
    startswith(dir, "/") ? dir : "${path.module}/${dir}"
  ]

  # Resolve each state name to the first directory that contains it
  state_paths = {
    for state in var.states :
    state => coalesce([
      for dir in local.resolved_dirs :
      "${dir}/${state}.yaml" if fileexists("${dir}/${state}.yaml")
    ]...)
  }

  # Load all state files
  state_files = [
    for state in var.states :
    yamldecode(file(local.state_paths[state]))
  ]

  # Deep merge all state files using union mode
  # Union mode: Deep merges maps recursively + deduplicates lists (treats them as sets)
  # Perfect for accumulating configs like tenants, regions, etc. without duplicates
  # With map-based structures (not lists), allows overriding specific nested fields
  # Build args: base with services and matrix keys + all state files + mode string, then expand with splat
  # Starting with {services = {}, matrix = {}} ensures both always exist, even with no state files
  merge_args = concat([{ services = {}, matrix = {} }], local.state_files, ["union"])

  # Always call merge - even with empty state_files, mergo returns the base object
  merged_state = provider::deepmerge::mergo(local.merge_args...)

  # Extract services from merged state
  # This is the single source of truth for service configuration
  # services key guaranteed to exist from initialization above
  final_service_configs = local.merged_state.services

  # Extract matrix from merged state
  # Matrix contains targeting dimensions (regions, tenants) used for deployment isolation
  # matrix key guaranteed to exist from initialization above
  final_matrix_configs = local.merged_state.matrix
}
