# Domains outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = module.aws.zone_id
}

output "zone_name" {
  description = "Route53 hosted zone name (e.g., dev-platform.example.com)"
  value       = module.aws.zone_name
}

output "certificate_arn" {
  description = "Validated ACM wildcard certificate ARN"
  value       = module.aws.certificate_arn
}

output "aliases" {
  description = "DNS alias map: FQDN -> compute class name"
  value       = module.aws.aliases
}
