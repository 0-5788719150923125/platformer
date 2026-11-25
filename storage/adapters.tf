# The AWS adapter's outputs, one local each. These are the values when the
# workspace doesn't use AWS; aws/wiring_override.tf.tmpl (linked in as
# adapter_aws_override.tf by scripts/providers.sh) points each at module.aws.
# One local per output keeps dependencies per output: referencing the module as
# a whole would tie every output to every other and close request round-trips
# (e.g. archivist -> storage -> archivist) into cycles.
locals {
  aws_wired = false

  aws_output_buckets                         = {}
  aws_output_bucket_names                    = {}
  aws_output_bucket_replacement_triggers     = {}
  aws_output_bucket_arns                     = {}
  aws_output_access_logs_bucket              = null
  aws_output_config                          = {}
  aws_output_rds_clusters                    = {}
  aws_output_rds_instances                   = {}
  aws_output_rds_instance_security_group_ids = {}
  aws_output_elasticache_clusters            = {}
  aws_output_rds_security_group_id           = 0
  aws_output_elasticache_security_group_id   = 0
  aws_output_repositories                    = {}
  aws_output_commands                        = []
  aws_output_inventory                       = []
  aws_output_access_security_groups          = []
  aws_output_access_resource_policies        = []
  aws_output_volumes                         = {}
  aws_output_repository_names                = {}
  aws_output_clone_urls                      = {}
}
