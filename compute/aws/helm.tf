# Helm Deployments for EKS Clusters (CLI-based)
# Deploys public Helm charts using helm CLI via null_resource
# This approach supports dynamic number of clusters (not possible with Helm provider)
#
# Architecture Decision:
# - Terraform's Helm provider is a singleton and cannot support dynamic cluster counts
# - CLI-based approach provides full flexibility for multi-cluster deployments
# - Consistent with existing kubeconfig_manager pattern using local-exec
# - Helm CLI is expected tooling for anyone working with Kubernetes/EKS

locals {
  # Flatten: cluster × helm_application → deployment map
  # Each helm request is paired with its target cluster metadata
  # Include tenant in key to handle same chart deployed for multiple tenants
  helm_deployments = merge([
    for class_name, class_config in local.eks_classes : {
      for app_idx, app in [
        for req in local.helm_application_requests : req
        if req.class == class_name
      ] :
      "${class_name}-${coalesce(app.tenant, "platform")}-${app.release_name}" => merge(app, {
        cluster_name   = aws_eks_cluster.cluster[class_name].name
        cluster_class  = class_name
        kubeconfig_ctx = class_name # Context name from kubeconfig_manager
      })
    }
  ]...)

  # Map: cluster_class → set of namespaces needed in that cluster
  # Each EKS cluster needs its own set of namespaces created
  namespaces_by_cluster = {
    for class_name in keys(local.eks_classes) :
    class_name => toset([
      for deployment in local.helm_deployments :
      deployment.namespace
      if deployment.cluster_class == class_name
    ])
  }

  # Flatten: cluster × namespace → unique key for resource creation
  namespace_resources = merge([
    for cluster_class, namespaces in local.namespaces_by_cluster : {
      for namespace in namespaces :
      "${cluster_class}-${namespace}" => {
        cluster_class = cluster_class
        namespace     = namespace
        context       = cluster_class # kubeconfig context matches cluster class name
      }
    }
  ]...)
}

# Create Kubernetes namespaces for Helm deployments
# Each namespace is created in its target cluster using kubectl CLI
resource "null_resource" "k8s_namespaces" {
  for_each = local.namespace_resources

  # Create namespace using kubectl (idempotent)
  provisioner "local-exec" {
    command = <<-EOT
      kubectl get namespace ${each.value.namespace} \
        --context=${each.value.context} 2>/dev/null || \
      kubectl create namespace ${each.value.namespace} \
        --context=${each.value.context}
    EOT
  }

  # Delete namespace on destroy
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl delete namespace ${self.triggers.namespace} \
        --context=${self.triggers.context} \
        --ignore-not-found=true
    EOT
  }

  triggers = {
    namespace   = each.value.namespace
    context     = each.value.context
    cluster_arn = aws_eks_cluster.cluster[each.value.cluster_class].arn
  }

  depends_on = [
    aws_eks_cluster.cluster,
    aws_eks_node_group.node_group,
    null_resource.kubeconfig_manager
  ]
}

# Helm Release Deployments (CLI-based via null_resource)
# Uses local-exec provisioner to invoke helm CLI for each deployment
# Triggers ensure Terraform tracks changes and recreates when needed
resource "null_resource" "helm_release" {
  for_each = local.helm_deployments

  # Install/upgrade Helm release using helm CLI
  provisioner "local-exec" {
    command = "${path.module}/scripts/deploy-helm-release.sh"
    environment = {
      CLUSTER_NAME       = each.value.cluster_name
      KUBECONFIG_CONTEXT = each.value.kubeconfig_ctx
      RELEASE_NAME       = each.value.release_name
      CHART              = each.value.chart
      REPOSITORY         = each.value.repository
      VERSION            = each.value.version
      NAMESPACE          = each.value.namespace
      WAIT               = each.value.wait ? "true" : "false"
      TIMEOUT            = each.value.timeout
      VALUES             = each.value.values != null ? each.value.values : ""
      # Pass AWS_PROFILE for cross-account ECR authentication
      AWS_PROFILE = var.aws_profile
    }
  }

  # Uninstall Helm release on destroy
  provisioner "local-exec" {
    when    = destroy
    command = "helm uninstall ${self.triggers.release_name} --namespace ${self.triggers.namespace} --kube-context ${self.triggers.context} 2>/dev/null || true"
    # AWS credentials inherited from Terraform environment
  }

  # Trigger recreation on any configuration change
  # This ensures Terraform tracks Helm release state via hash comparison
  triggers = {
    cluster_name = each.value.cluster_name
    release_name = each.value.release_name
    chart        = each.value.chart
    repository   = each.value.repository
    version      = each.value.version
    namespace    = each.value.namespace
    context      = each.value.kubeconfig_ctx
    values_hash  = each.value.values != null ? md5(each.value.values) : ""
  }

  depends_on = [
    aws_eks_cluster.cluster,
    aws_eks_node_group.node_group,
    aws_eks_addon.addon,              # Ensure addons (e.g., EBS CSI driver) are ready
    null_resource.kubeconfig_manager, # Ensure kubeconfig context exists
    null_resource.k8s_namespaces      # Ensure namespace exists before deploying Helm charts
  ]
}
