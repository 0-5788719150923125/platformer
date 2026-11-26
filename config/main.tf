# Config Module
# Resolves final service configuration by loading and deep-merging YAML fragments
# Uses deepmerge provider for native type preservation and plan-time validation

locals {
  # Resolve each fragment_dirs entry: absolute paths are used verbatim,
  # relative paths are prefixed with path.module for backward compatibility
  # with Platformer's own usage (which passes e.g. "../fragments" to mean
  # "up one level from the config module").
  resolved_dirs = [
    for dir in var.fragment_dirs :
    startswith(dir, "/") ? dir : "${path.module}/${dir}"
  ]

  # Resolve each fragment name to the first directory that contains it.
  # (var.fragment_dirs validation guarantees every dir exists.)
  fragment_candidates = {
    for fragment in var.fragments :
    fragment => [
      for dir in local.resolved_dirs :
      "${dir}/${fragment}.yaml" if fileexists("${dir}/${fragment}.yaml")
    ]
  }

  # A missing fragment fails with an explicit message (the tobool() of a
  # non-bool string is a deliberate plan-time error carrying the text). The
  # previous coalesce([]...) idiom errored too, but with a cryptic type message.
  fragment_files = {
    for fragment, candidates in local.fragment_candidates :
    fragment => length(candidates) > 0 ? candidates[0] : tobool(
      "ERROR: fragment '${fragment}' not found in any fragments dir: ${join(", ", local.resolved_dirs)}"
    )
  }

  # Catalog of every fragment available in catalog_dirs (defaults to
  # fragment_dirs), not just the selected ones. Same first-match-wins rule:
  # walk dirs in reverse so earlier dirs overwrite later ones in merge().
  resolved_catalog_dirs = var.catalog_dirs == null ? local.resolved_dirs : [
    for dir in var.catalog_dirs :
    startswith(dir, "/") ? dir : "${path.module}/${dir}"
  ]
  available_fragments = merge([
    for dir in reverse(local.resolved_catalog_dirs) : {
      for f in fileset(dir, "*.yaml") : trimsuffix(f, ".yaml") => "${dir}/${f}"
    }
  ]...)

  # Load every selected fragment
  fragment_contents = [
    for fragment in var.fragments :
    yamldecode(file(local.fragment_files[fragment]))
  ]

  # Deep merge all fragments using union mode
  # Union mode: Deep merges maps recursively + deduplicates lists (treats them as sets)
  # Perfect for accumulating configs like tenants, regions, etc. without duplicates
  # With map-based structures (not lists), allows overriding specific nested fields
  # Build args: base with services and matrix keys + all fragments + mode string, then expand with splat
  # Starting with {services = {}, matrix = {}} ensures both always exist, even with no fragments
  merge_args = concat([{ services = {}, matrix = {} }], local.fragment_contents, ["union"])

  # Always call merge - even with no fragments, mergo returns the base object
  merged = provider::deepmerge::mergo(local.merge_args...)

  # Extract services from the merged fragments
  # This is the single source of truth for service configuration
  # services key guaranteed to exist from initialization above
  final_service_configs = local.merged.services

  # Extract matrix from the merged fragments
  # Matrix contains targeting dimensions (regions, tenants) used for deployment isolation
  # matrix key guaranteed to exist from initialization above
  final_matrix_configs = local.merged.matrix
}
