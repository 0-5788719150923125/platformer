# Compute outputs
#
# Same names as before the AWS adapter split, so callers see no difference.
# AWS values come from compute/aws/; adapter values are generic (adapters.tf).

output "instances" {
  description = "Deployed tenant instances with metadata"
  value       = module.aws.instances
}

output "instance_keys" {
  description = "List of instance keys derived from config (plan-time safe for for_each)"
  value       = module.aws.instance_keys
}

output "service_instance_keys" {
  description = "Instance keys for classes with ingress rules (plan-time safe, for service URL filtering)"
  value       = module.aws.service_instance_keys
}

output "config" {
  description = "Compute service configuration summary"
  value       = module.aws.config
}

output "instances_by_tenant" {
  description = "Instances grouped by tenant code"
  value       = module.aws.instances_by_tenant
}

output "instances_by_class" {
  description = "Instances grouped by class name - map of class_name => { instance_key => instance_id }"
  value       = module.aws.instances_by_class
}

output "eks_clusters" {
  description = "Deployed EKS clusters with metadata"
  value       = module.aws.eks_clusters
}

output "eks_cluster_security_groups" {
  description = "EKS cluster security group IDs (map: class_name => security_group_id)"
  value       = module.aws.eks_cluster_security_groups
}

output "eks_node_groups" {
  description = "Deployed EKS node groups with metadata"
  value       = module.aws.eks_node_groups
}

output "eks_test_commands" {
  description = "Commands to test EKS cluster connectivity (kubeconfig managed automatically)"
  value       = module.aws.eks_test_commands
}

output "application_requests" {
  description = "Application installation requests for applications module"
  value       = module.aws.application_requests
}

output "cluster_application_requests" {
  description = "Per-instance cluster application requests for mode: 1-master classes (not fed back to compute)"
  value       = module.aws.cluster_application_requests
}

output "instance_role_arn" {
  description = "IAM role ARN for compute instances (for S3 bucket policy)"
  value       = module.aws.instance_role_arn
}

output "instance_role_name" {
  description = "IAM role name for compute instances (for attaching policies)"
  value       = module.aws.instance_role_name
}

output "eks_node_role_name" {
  description = "EKS node group IAM role name (for attaching policies)"
  value       = module.aws.eks_node_role_name
}

output "alb_dns_names" {
  description = "Map of instance_key to FQDN for HTTPS ALB instances"
  value       = module.aws.alb_dns_names
}

output "http_dns_names" {
  description = "Map of instance_key to FQDN for HTTP instances with domain"
  value       = module.aws.http_dns_names
}

output "alias_fqdn_by_class" {
  description = "Map of compute class name to alias FQDN (first alias per class)"
  value       = module.aws.alias_fqdn_by_class
}

output "lb_dns_names" {
  description = "NLB DNS names for EKS services (keyed by cluster_class-name)"
  value       = module.aws.lb_dns_names
}

output "helm_releases" {
  description = "Deployed Helm releases with metadata and access commands"
  value       = module.aws.helm_releases
}

output "commands" {
  description = "Standardized operational commands for CLI display and portal actions"
  value       = module.aws.commands
}

output "kubeconfig_ready" {
  description = "Dependency marker indicating kubeconfig contexts are set up"
  value       = module.aws.kubeconfig_ready
}

output "ecs_clusters" {
  description = "Deployed ECS clusters with metadata"
  value       = module.aws.ecs_clusters
}

output "volume_requests" {
  description = "EBS volume + attachment requests for the storage module"
  value       = module.aws.volume_requests
}

output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = module.aws.access_requests
}

output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = module.aws.access_security_groups
}

output "ecs_test_commands" {
  description = "Commands to debug ECS clusters, services, and tasks"
  value       = module.aws.ecs_test_commands
}

# Cloud adapters (see adapters.tf)
output "adapter_instances" {
  description = "Instances run by cloud adapters (type = instance), by cloud, then instance key"
  value       = { for cloud, adapter in local.adapters : cloud => adapter.instances }

  precondition {
    condition     = alltrue([for cloud in keys(local.adapter_config) : contains(keys(local.adapters), cloud)])
    error_message = "Compute classes use clouds with no adapter wired in: [${join(", ", [for cloud in keys(local.adapter_config) : cloud if !contains(keys(local.adapters), cloud)])}]. Declare the cloud in terraform.tfvars.<workspace> (e.g. oci_profile = \"DEFAULT\") and run scripts/providers.sh."
  }

  precondition {
    condition     = length(local.ambiguous_adoptions) == 0
    error_message = "Classes with `adopt` must be entitled to exactly one active tenant (adopt maps list indexes to instances; tenants must be registered in tenants/tenants.yaml): ${join(", ", local.ambiguous_adoptions)}"
  }
}

output "adoptions" {
  description = "Existing instances to adopt (import) instead of create, by cloud, then instance key => cloud resource ID"
  value       = local.adoptions
}
