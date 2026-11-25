# The AWS adapter's outputs, one local each. These are the values when the
# workspace doesn't use AWS; aws/wiring_override.tf.tmpl (linked in as
# adapter_aws_override.tf by scripts/providers.sh) points each at module.aws.
# One local per output keeps dependencies per output: referencing the module as
# a whole would tie every output to every other and close request round-trips
# (e.g. archivist -> storage -> archivist) into cycles.
locals {
  aws_wired = false

  aws_output_iam_role_arns          = {}
  aws_output_iam_role_names         = {}
  aws_output_instance_profile_names = {}
  aws_output_instance_profile_arns  = {}
  aws_output_bucket_requests        = []
  aws_output_report_ready           = ""
  aws_output_artifact_requests      = []
  aws_output_report_path            = ""
  aws_output_access_summary         = {}
}
