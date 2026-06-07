# Helm Application Requests for EKS deployments
# Generates Helm chart deployment definitions for EKS tenants
# EC2 tenants continue using Ansible-based deployment via SSM

# Query frontend LoadBalancer service URL from Kubernetes
# This enables portal widget to display actual URLs instead of null placeholders
data "external" "frontend_service_url" {
  for_each = var.kubeconfig_ready != {} ? local.eks_deployment_tenants : {}

  program = ["bash", "-c", <<-EOF
    # Get LoadBalancer hostname using kubectl
    hostname=$(kubectl get svc frontend -n ${each.value.tenant} --context ${each.value.deployment} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    # If hostname is empty, try IP (for some cloud providers)
    if [ -z "$hostname" ]; then
      hostname=$(kubectl get svc frontend -n ${each.value.tenant} --context ${each.value.deployment} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    fi
    # Return JSON (external data source requires all values to be strings)
    echo "{\"hostname\":\"$hostname\"}"
  EOF
  ]

  # Only query after Helm charts are deployed and kubeconfig is ready
  depends_on = [var.kubeconfig_ready]
}

locals {
  # Generate Helm requests for each EKS deployment-tenant (5 charts × N deployment-tenants)
  # These are consumed by compute module's Helm deployment mechanism
  helm_requests = flatten([
    for key, dt in local.eks_deployment_tenants : [
      # 1. Services Chart (v3 services, pgbouncer, etc.)
      {
        type         = "helm"
        chart        = "services"
        repository   = "oci://${var.config[dt.deployment].ecr_registry}"
        version      = "2.1.2"
        namespace    = dt.tenant
        release_name = "services"
        values = templatefile("${path.module}/templates/services-values.yaml.tpl", {
          redis_services_endpoint = local.cache_endpoints[key].redis_services_endpoint
          memcached_endpoint      = local.cache_endpoints[key].memcached_endpoint
        })
        wait    = true
        timeout = 600
        tenant  = dt.tenant
        class   = dt.deployment
      },
      # 2. Storage Chart (imagedb services)
      {
        type         = "helm"
        chart        = "storage"
        repository   = "oci://${var.config[dt.deployment].ecr_registry}"
        version      = "3.15.0"
        namespace    = dt.tenant
        release_name = "storage"
        values = templatefile("${path.module}/templates/storage-values.yaml.tpl", {
          tenant_namespace       = dt.tenant
          redis_storage_endpoint = local.cache_endpoints[key].redis_storage_endpoint
          aws_region             = data.aws_region.current.id
        })
        wait    = true
        timeout = 600
        tenant  = dt.tenant
        class   = dt.deployment
      },
      # 3. Transcoding Chart (DICOM transcoding services)
      {
        type         = "helm"
        chart        = "transcoding"
        repository   = "oci://${var.config[dt.deployment].ecr_registry}"
        version      = "2.0.6"
        namespace    = dt.tenant
        release_name = "transcoding"
        values       = templatefile("${path.module}/templates/transcoding-values.yaml.tpl", {})
        wait         = true
        timeout      = 600
        tenant       = dt.tenant
        class        = dt.deployment
      },
      # 4. Watchdog Chart (monitoring and health checks)
      {
        type         = "helm"
        chart        = "watchdogservices"
        repository   = "oci://${var.config[dt.deployment].ecr_registry}"
        version      = "1.2.2"
        namespace    = dt.tenant
        release_name = "watchdog"
        values = templatefile("${path.module}/templates/watchdog-values.yaml.tpl", {
          tenant_namespace = dt.tenant
        })
        wait    = true
        timeout = 600
        tenant  = dt.tenant
        class   = dt.deployment
      },
      # 5. Frontend Chart (web UI)
      {
        type         = "helm"
        chart        = "frontend"
        repository   = "oci://${var.config[dt.deployment].ecr_registry}"
        version      = "1.5.2"
        namespace    = dt.tenant
        release_name = "frontend"
        values = templatefile("${path.module}/templates/frontend-values.yaml.tpl", {
          tenant_namespace = dt.tenant
        })
        wait    = true
        timeout = 600
        tenant  = dt.tenant
        class   = dt.deployment
      }
    ]
  ])
}
