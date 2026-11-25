# Compute outputs
#
# Same names as before the AWS adapter split, so callers see no difference.
# AWS values come from compute/aws/; adapter values are generic (adapters.tf).

output "instances" {
  description = "Deployed tenant instances with metadata"
  value       = local.aws_output_instances
}

output "instance_keys" {
  description = "List of instance keys derived from config (plan-time safe for for_each)"
  value       = local.aws_output_instance_keys
}

output "service_instance_keys" {
  description = "Instance keys for classes with ingress rules (plan-time safe, for service URL filtering)"
  value       = local.aws_output_service_instance_keys
}

output "config" {
  description = "Compute service configuration summary"
  value       = local.aws_output_config
}

output "instances_by_tenant" {
  description = "Instances grouped by tenant code"
  value       = local.aws_output_instances_by_tenant
}

output "instances_by_class" {
  description = "Instances grouped by class name - map of class_name => { instance_key => instance_id }"
  value       = local.aws_output_instances_by_class
}

output "eks_clusters" {
  description = "Deployed EKS clusters with metadata"
  value       = local.aws_output_eks_clusters
}

output "eks_cluster_security_groups" {
  description = "EKS cluster security group IDs (map: class_name => security_group_id)"
  value       = local.aws_output_eks_cluster_security_groups
}

output "eks_node_groups" {
  description = "Deployed EKS node groups with metadata"
  value       = local.aws_output_eks_node_groups
}

output "eks_test_commands" {
  description = "Commands to test EKS cluster connectivity (kubeconfig managed automatically)"
  value       = local.aws_output_eks_test_commands
}

output "application_requests" {
  description = "Application installation requests for applications module"
  value       = local.aws_output_application_requests
}

output "cluster_application_requests" {
  description = "Per-instance cluster application requests for mode: 1-master classes (not fed back to compute)"
  value       = local.aws_output_cluster_application_requests
}

output "instance_role_arn" {
  description = "IAM role ARN for compute instances (for S3 bucket policy)"
  value       = local.aws_output_instance_role_arn
}

output "instance_role_name" {
  description = "IAM role name for compute instances (for attaching policies)"
  value       = local.aws_output_instance_role_name
}

output "eks_node_role_name" {
  description = "EKS node group IAM role name (for attaching policies)"
  value       = local.aws_output_eks_node_role_name
}

output "alb_dns_names" {
  description = "Map of instance_key to FQDN for HTTPS ALB instances"
  value       = local.aws_output_alb_dns_names
}

output "http_dns_names" {
  description = "Map of instance_key to FQDN for HTTP instances with domain"
  value       = local.aws_output_http_dns_names
}

output "alias_fqdn_by_class" {
  description = "Map of compute class name to alias FQDN (first alias per class)"
  value       = local.aws_output_alias_fqdn_by_class
}

output "lb_dns_names" {
  description = "NLB DNS names for EKS services (keyed by cluster_class-name)"
  value       = local.aws_output_lb_dns_names
}

output "helm_releases" {
  description = "Deployed Helm releases with metadata and access commands"
  value       = local.aws_output_helm_releases
}

output "commands" {
  description = "Standardized operational commands for CLI display and portal actions"
  value       = local.aws_output_commands
}

output "kubeconfig_ready" {
  description = "Dependency marker indicating kubeconfig contexts are set up"
  value       = local.aws_output_kubeconfig_ready
}

output "ecs_clusters" {
  description = "Deployed ECS clusters with metadata"
  value       = local.aws_output_ecs_clusters
}

output "volume_requests" {
  description = "EBS volume + attachment requests for the storage module"
  value       = local.aws_output_volume_requests
}

output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = local.aws_output_access_requests
}

output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = local.aws_output_access_security_groups
}

output "ecs_test_commands" {
  description = "Commands to debug ECS clusters, services, and tasks"
  value       = local.aws_output_ecs_test_commands
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
    condition = local.aws_wired || length([
      for class_name, class_config in var.config : class_name
      if(contains(["ec2", "eks", "ecs"], class_config.type) || (class_config.type == "instance" && class_config.cloud == "aws")) && length(lookup(var.tenants_by_class, class_name, [])) > 0
    ]) == 0
    error_message = "Compute classes need AWS (type ec2, eks or ecs, or cloud = aws), but AWS isn't wired into this workspace. Set aws_profile in terraform.tfvars.<workspace> and run scripts/providers.sh."
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
