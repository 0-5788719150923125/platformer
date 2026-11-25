# The AWS implementation moved into secrets/aws/ (2026-11-25). These blocks carry
# existing state to the new addresses, so nothing is destroyed or recreated.
# Data sources need no moves; they are simply read again.

moved {
  from = aws_secretsmanager_secret.replicated
  to   = module.aws.aws_secretsmanager_secret.replicated
}

moved {
  from = aws_secretsmanager_secret_version.replicated
  to   = module.aws.aws_secretsmanager_secret_version.replicated
}

moved {
  from = aws_secretsmanager_secret_policy.account_read
  to   = module.aws.aws_secretsmanager_secret_policy.account_read
}

moved {
  from = aws_ssm_parameter.replicated
  to   = module.aws.aws_ssm_parameter.replicated
}
