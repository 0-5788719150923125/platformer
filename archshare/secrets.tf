# Kubernetes Secrets for EKS deployments
# Creates K8s secrets containing RDS/ElastiCache/S3 endpoints for Archshare applications
# EC2 deployments handle secrets via Ansible playbooks instead

resource "null_resource" "eks_secrets" {
  for_each = local.eks_deployment_tenants

  # Triggers for recreation when any configuration changes
  # IMPORTANT: kubeconfig_dependency creates implicit dependency on compute module's kubeconfig_manager
  # This ensures EKS cluster exists and kubectl context is configured before running kubectl commands
  triggers = {
    tenant                = each.value.tenant
    deployment            = each.value.deployment
    namespace             = var.namespace
    kubectl_context       = each.value.deployment
    kubeconfig_dependency = jsonencode(var.kubeconfig_ready) # Dependency ordering: wait for kubeconfig
    rds_services_endpoint = local.rds_endpoints[each.key].services_endpoint
    rds_services_password = local.rds_endpoints[each.key].services_password
    rds_storage_endpoint  = local.rds_endpoints[each.key].storage_endpoint
    rds_storage_password  = local.rds_endpoints[each.key].storage_password
    redis_services        = local.cache_endpoints[each.key].redis_services_endpoint
    redis_storage         = local.cache_endpoints[each.key].redis_storage_endpoint
    memcached             = local.cache_endpoints[each.key].memcached_endpoint
    s3_bucket             = local.s3_buckets[each.key]
    ecr_registry          = var.config[each.value.deployment].ecr_registry
    aws_region            = data.aws_region.current.id
    script_hash           = filemd5("${path.module}/scripts/create-k8s-secrets.sh")
  }

  # Create Kubernetes secrets via shell script
  provisioner "local-exec" {
    command = "${path.module}/scripts/create-k8s-secrets.sh"
    environment = {
      TENANT                = each.value.tenant
      NAMESPACE             = var.namespace
      KUBECTL_CONTEXT       = self.triggers.kubectl_context
      AWS_REGION            = self.triggers.aws_region
      RDS_SERVICES_ENDPOINT = self.triggers.rds_services_endpoint
      RDS_SERVICES_PASSWORD = self.triggers.rds_services_password
      RDS_STORAGE_ENDPOINT  = self.triggers.rds_storage_endpoint
      RDS_STORAGE_PASSWORD  = self.triggers.rds_storage_password
      REDIS_SERVICES        = self.triggers.redis_services
      REDIS_STORAGE         = self.triggers.redis_storage
      MEMCACHED             = self.triggers.memcached
      S3_BUCKET             = self.triggers.s3_bucket
      ECR_REGISTRY          = self.triggers.ecr_registry
    }
  }
}

# Data source for current region
data "aws_region" "current" {}
