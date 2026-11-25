# The AWS adapter's outputs, one local each. These are the values when the
# workspace doesn't use AWS; aws/wiring_override.tf.tmpl (linked in as
# adapter_aws_override.tf by scripts/providers.sh) points each at module.aws.
# One local per output keeps dependencies per output: referencing the module as
# a whole would tie every output to every other and close request round-trips
# (e.g. archivist -> storage -> archivist) into cycles.
locals {
  aws_wired = false

  aws_output_built_amis        = {}
  aws_output_artifact_requests = []
  aws_output_access_requests   = []
  aws_output_commands          = []
}
