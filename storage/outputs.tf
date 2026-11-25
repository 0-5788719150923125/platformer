# Storage outputs
#
# Same names as before the AWS adapter split, so callers see no difference.

output "buckets" {
  description = "S3 buckets created from bucket_requests (keyed by purpose)"
  value       = local.aws_output_buckets
}

output "bucket_names" {
  description = "Map of purpose => bucket name"
  value       = local.aws_output_bucket_names
}

output "bucket_replacement_triggers" {
  description = "Map of purpose => trigger ID that changes when the bucket is recreated"
  value       = local.aws_output_bucket_replacement_triggers
}

output "bucket_arns" {
  description = "Map of purpose => bucket ARN"
  value       = local.aws_output_bucket_arns
}

output "access_logs_bucket" {
  description = "Centralized access logs bucket (if any bucket requested access_logging)"
  value       = local.aws_output_access_logs_bucket
}

output "config" {
  description = "Storage service configuration summary"
  value       = local.aws_output_config
}

output "rds_clusters" {
  description = "RDS Aurora clusters created from rds_cluster_requests (keyed by purpose)"
  value       = local.aws_output_rds_clusters
  sensitive   = true
}

output "rds_instances" {
  description = "RDS standalone instances created from rds_instance_requests (keyed by purpose)"
  value       = local.aws_output_rds_instances
  sensitive   = true
}

output "rds_instance_security_group_ids" {
  description = "RDS instance security group IDs (map: purpose => sg_id)"
  value       = local.aws_output_rds_instance_security_group_ids
}

output "elasticache_clusters" {
  description = "ElastiCache clusters created from elasticache_cluster_requests (keyed by purpose)"
  value       = local.aws_output_elasticache_clusters
}

output "rds_security_group_id" {
  description = "RDS security group ID (for adding ingress rules)"
  value       = local.aws_output_rds_security_group_id
}

output "elasticache_security_group_id" {
  description = "ElastiCache security group ID (for adding ingress rules)"
  value       = local.aws_output_elasticache_security_group_id
}

output "repositories" {
  description = "CodeCommit repositories created from repository_requests (keyed by purpose)"
  value       = local.aws_output_repositories
}

output "commands" {
  description = "Portal self-service action commands from the storage module"
  value       = local.aws_output_commands
}

output "inventory" {
  description = "Non-sensitive storage resource summary for portal catalog (keyed by purpose)"
  value       = local.aws_output_inventory
}

output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = local.aws_output_access_security_groups
}

output "access_resource_policies" {
  description = "S3 bucket policies for the access module (AWS-native format)"
  value       = local.aws_output_access_resource_policies
}

output "volumes" {
  description = "EBS volumes created from volume_requests (keyed by purpose)"
  value       = local.aws_output_volumes
}

output "repository_names" {
  description = "Map of purpose => repository name"
  value       = local.aws_output_repository_names
}

output "clone_urls" {
  description = "Map of purpose => HTTPS clone URL"
  value       = local.aws_output_clone_urls
}
