# The AWS implementation moved into access/aws/ (2026-11-25). These blocks carry
# existing state to the new addresses, so nothing is destroyed or recreated.
# Data sources need no moves; they are simply read again.

moved {
  from = aws_iam_role.requested
  to   = module.aws.aws_iam_role.requested
}

moved {
  from = aws_iam_role_policy.requested
  to   = module.aws.aws_iam_role_policy.requested
}

moved {
  from = aws_iam_role_policy_attachment.requested
  to   = module.aws.aws_iam_role_policy_attachment.requested
}

moved {
  from = aws_iam_instance_profile.requested
  to   = module.aws.aws_iam_instance_profile.requested
}

moved {
  from = local_file.access_report_compact
  to   = module.aws.local_file.access_report_compact
}

moved {
  from = null_resource.access_report
  to   = module.aws.null_resource.access_report
}
