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

output "archshare" {
  description = "Enable archshare module (explicitly configured)"
  value       = local.module_requirements.archshare
}

output "archpacs" {
  description = "Enable archpacs module (explicitly configured)"
  value       = local.module_requirements.archpacs
}

output "archorchestrator" {
  description = "Enable archorchestrator module (explicitly configured)"
  value       = local.module_requirements.archorchestrator
}

output "portal" {
  description = "Enable portal module (explicit opt-in required)"
  value       = local.module_requirements.portal
}

output "observability" {
  description = "Enable observability module (explicitly configured)"
  value       = local.module_requirements.observability
}

output "archbot" {
  description = "Enable archbot module (explicitly configured)"
  value       = local.module_requirements.archbot
}
