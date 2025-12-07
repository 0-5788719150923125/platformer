# Unified output - all enriched application requests
# Consumer modules filter internally by type (ssm, ansible, user-data, helm)
output "requests" {
  description = "All enriched application requests - consumer modules filter by type field"
  value       = local.enriched_requests
}
