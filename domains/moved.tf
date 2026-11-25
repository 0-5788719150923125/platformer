# The AWS implementation moved into domains/aws/ (2026-11-25). These blocks carry
# existing state to the new addresses, so nothing is destroyed or recreated.
# Data sources need no moves; they are simply read again.

moved {
  from = aws_acm_certificate.wildcard
  to   = module.aws.aws_acm_certificate.wildcard
}

moved {
  from = aws_route53_record.cert_validation
  to   = module.aws.aws_route53_record.cert_validation
}

moved {
  from = aws_acm_certificate_validation.wildcard
  to   = module.aws.aws_acm_certificate_validation.wildcard
}
