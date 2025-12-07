output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = data.aws_route53_zone.zone.zone_id
}

output "zone_name" {
  description = "Route53 hosted zone name (e.g., dev-platform.example.com)"
  value       = data.aws_route53_zone.zone.name
}

output "certificate_arn" {
  description = "Validated ACM wildcard certificate ARN"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}
