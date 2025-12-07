# Domains Module
# Looks up an existing Route53 hosted zone and provisions a wildcard ACM certificate
# with DNS validation. Used by compute module for HTTPS ALB termination.
#
# State fragment example:
#   services:
#     domains:
#       zone: dev-platform.example.com

# Look up the existing Route53 hosted zone (must already exist)
data "aws_route53_zone" "zone" {
  name         = var.config.zone
  private_zone = false
}

# Wildcard ACM certificate for *.{zone}
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.config.zone}"
  validation_method = "DNS"

  tags = {
    Name      = "wildcard.${var.config.zone}"
    Namespace = var.namespace
  }

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation records
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.zone.zone_id
}

# Wait for certificate validation to complete
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
