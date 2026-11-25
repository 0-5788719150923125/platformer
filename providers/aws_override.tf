# Adds AWS to the root's required_providers (providers.tf) and points core's
# AWS values (main.tf) at what AWS reports. Linked into the root as
# provider_aws_override.tf by scripts/providers.sh.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.region

  arcbot_access_requests               = local.arcbot_enabled ? module.arcbot[0].access_requests : null
  arcbot_access_resource_policies      = local.arcbot_enabled ? module.arcbot[0].access_resource_policies : null
  arcbot_bucket_requests               = local.arcbot_enabled ? module.arcbot[0].bucket_requests : null
  arcbot_commands                      = local.arcbot_enabled ? module.arcbot[0].commands : null
  arcbot_event_bus_requests            = local.arcbot_enabled ? module.arcbot[0].event_bus_requests : null
  arcbot_service_url_entries           = local.arcbot_enabled ? module.arcbot[0].service_url_entries : null
  iopacs_access_security_groups        = local.iopacs_enabled ? module.iopacs[0].access_security_groups : null
  iopacs_bucket_requests               = local.iopacs_enabled ? module.iopacs[0].bucket_requests : null
  iopacs_compute_class_requests        = local.iopacs_enabled ? module.iopacs[0].compute_class_requests : null
  iopacs_rds_cluster_requests          = local.iopacs_enabled ? module.iopacs[0].rds_cluster_requests : null
  iorchestrator_access_requests        = local.iorchestrator_enabled ? module.iorchestrator[0].access_requests : null
  iorchestrator_access_security_groups = local.iorchestrator_enabled ? module.iorchestrator[0].access_security_groups : null
  iorchestrator_alb_urls               = local.iorchestrator_enabled ? module.iorchestrator[0].alb_urls : null
  iorchestrator_bucket_requests        = local.iorchestrator_enabled ? module.iorchestrator[0].bucket_requests : null
  iorchestrator_compute_class_requests = local.iorchestrator_enabled ? module.iorchestrator[0].compute_class_requests : null
  iorchestrator_rds_cluster_requests   = local.iorchestrator_enabled ? module.iorchestrator[0].rds_cluster_requests : null
  ioshare_ansible_bucket_request       = local.ioshare_enabled ? module.ioshare[0].ansible_bucket_request : null
  ioshare_bucket_requests              = local.ioshare_enabled ? module.ioshare[0].bucket_requests : null
  ioshare_compute_class_requests       = local.ioshare_enabled ? module.ioshare[0].compute_class_requests : null
  ioshare_eks_deployment_tenants       = local.ioshare_enabled ? module.ioshare[0].eks_deployment_tenants : null
  ioshare_elasticache_cluster_requests = local.ioshare_enabled ? module.ioshare[0].elasticache_cluster_requests : null
  ioshare_frontend_service_urls        = local.ioshare_enabled ? module.ioshare[0].frontend_service_urls : null
  ioshare_helm_application_requests    = local.ioshare_enabled ? module.ioshare[0].helm_application_requests : null
  ioshare_rds_cluster_requests         = local.ioshare_enabled ? module.ioshare[0].rds_cluster_requests : null
  legacy_access_requests               = local.legacy_enabled ? module.legacy[0].access_requests : null
}
