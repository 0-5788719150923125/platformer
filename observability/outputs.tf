# Dependency inversion interfaces - export requests for root orchestrator

output "compute_class_requests" {
  description = "EKS cluster definition for the observability stack (merged into effective_compute_config)"
  value       = local.compute_class_requests
}

output "bucket_requests" {
  description = "S3 bucket requests for Loki storage (chunks + ruler)"
  value       = local.bucket_requests
}

output "helm_application_requests" {
  description = "Helm chart deployment requests for Loki and Grafana"
  value       = local.helm_application_requests
}

output "alloy_application_requests" {
  description = "Ansible application requests for Grafana Alloy agent deployment to EC2"
  value       = local.alloy_application_requests
}

output "pod_identity_requests" {
  description = "Pod Identity requests for EKS workloads needing IAM access (e.g., Loki S3)"
  value       = local.pod_identity_requests
}

output "lb_requests" {
  description = "NLB requests for Terraform-managed load balancers (Loki gateway, Grafana)"
  value       = local.lb_requests
}

output "alloy_helm_template" {
  description = "Alloy Helm template for non-observability EKS clusters (LOKI_PUSH_ENDPOINT/MIMIR_REMOTE_WRITE_ENDPOINT/CLUSTER_NAME placeholders)"
  value       = local.alloy_helm_template
}

output "kube_state_metrics_helm_template" {
  description = "kube-state-metrics Helm template for non-observability EKS clusters"
  value       = local.kube_state_metrics_helm_template
}

output "prometheus_node_exporter_helm_template" {
  description = "prometheus-node-exporter Helm template for non-observability EKS clusters"
  value       = local.prometheus_node_exporter_helm_template
}

