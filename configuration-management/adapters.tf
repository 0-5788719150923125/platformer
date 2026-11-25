# The AWS adapter's outputs, one local each. These are the values when the
# workspace doesn't use AWS; aws/wiring_override.tf.tmpl (linked in as
# adapter_aws_override.tf by scripts/providers.sh) points each at module.aws.
# One local per output keeps dependencies per output: referencing the module as
# a whole would tie every output to every other and close request round-trips
# (e.g. archivist -> storage -> archivist) into cycles.
locals {
  aws_wired = false

  aws_output_documents                  = {}
  aws_output_application_associations   = {}
  aws_output_ansible_controller         = null
  aws_output_ansible_playbooks_uploaded = []
  aws_output_config                     = {}
  aws_output_trigger_execution          = {}
  aws_output_check_execution_status     = {}
  aws_output_instance_parameters        = []
  aws_output_bucket_requests            = []
  aws_output_patch_management_enabled   = false
  aws_output_patch_management_summary   = {}
  aws_output_patch_management_by_class  = {}
  aws_output_baselines                  = {}
  aws_output_patch_groups_by_class      = {}
  aws_output_commands                   = []
  aws_output_docker_test_commands       = {}
  aws_output_access_requests            = []
  aws_output_event_bus_requests         = []
}
