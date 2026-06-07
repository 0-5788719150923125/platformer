output "enabled" {
  description = "Map of module name to enabled status"
  value       = local.module_requirements
}

output "storage" {
  description = "Enable storage module (explicitly configured or needed by other modules)"
  value       = local.module_requirements.storage
}

output "compute" {
  description = "Enable compute module (explicitly configured or needed by other modules)"
  value       = local.module_requirements.compute
}

output "configuration_management" {
  description = "Enable configuration-management module (explicitly configured)"
  value       = local.module_requirements.configuration_management
}

output "domains" {
  description = "Enable domains module (explicitly configured)"
  value       = local.module_requirements.domains
}

output "secrets" {
  description = "Enable secrets module (explicitly configured)"
  value       = local.module_requirements.secrets
}

output "legacy" {
  description = "Enable legacy module (explicitly configured)"
  value       = local.module_requirements.legacy
}

output "clairevoyance" {
  description = "Enable clairevoyance module (explicitly configured)"
  value       = local.module_requirements.clairevoyance
}

output "applications" {
  description = "Enable applications module (auto-enabled when compute has applications)"
  value       = local.module_requirements.applications
}

output "ioshare" {
  description = "Enable ioshare module (explicitly configured)"
  value       = local.module_requirements.ioshare
}

output "iopacs" {
  description = "Enable iopacs module (explicitly configured)"
  value       = local.module_requirements.iopacs
}

output "iorchestrator" {
  description = "Enable iorchestrator module (explicitly configured)"
  value       = local.module_requirements.iorchestrator
}

output "portal" {
  description = "Enable portal module (explicit opt-in required)"
  value       = local.module_requirements.portal
}

output "observability" {
  description = "Enable observability module (explicitly configured)"
  value       = local.module_requirements.observability
}

output "arcbot" {
  description = "Enable arcbot module (explicitly configured)"
  value       = local.module_requirements.arcbot
}
