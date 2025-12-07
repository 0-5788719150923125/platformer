# Instance inventory
output "instances" {
  description = "Deployed tenant instances with metadata"
  value = {
    for key, instance in aws_instance.tenant :
    key => {
      id            = instance.id
      private_ip    = instance.private_ip
      public_ip     = instance.public_ip
      public_dns    = instance.public_dns
      subnet_id     = instance.subnet_id
      ami           = instance.ami
      tenant        = instance.tags["Tenant"]
      class         = instance.tags["Class"]
      instance_idx  = local.tenant_instances[key].instance_idx
      instance_type = instance.instance_type
      ingress_ports = [for rule in coalesce(local.ec2_classes[instance.tags["Class"]].ingress, []) : rule.port]
    }
  }
}

# Config-derived instance keys (plan-time safe, no resource dependencies)
# Use this for for_each maps where keys must be known at plan time
output "instance_keys" {
  description = "List of instance keys derived from config (plan-time safe for for_each)"
  value       = keys(local.tenant_instances)
}

# Instance keys for classes that expose a web service (have ingress rules configured)
# Plan-time safe - used to filter service URL entities so bare instances (e.g. rocky-linux)
# don't appear in the portal widget with empty links
output "service_instance_keys" {
  description = "Instance keys for classes with ingress rules (plan-time safe, for service URL filtering)"
  value = [
    for key, instance in local.tenant_instances : key
    if length(coalesce(local.ec2_classes[instance.class].ingress, [])) > 0
  ]
}

# Configuration summary
output "config" {
  description = "Compute service configuration summary"
  value = {
    tenants         = local.effective_tenants
    classes         = [for c in keys(var.config) : c if length(lookup(var.tenants_by_class, c, [])) > 0]
    total_instances = length(aws_instance.tenant)
  }
}

# Tenant grouping
output "instances_by_tenant" {
  description = "Instances grouped by tenant code"
  value = {
    for tenant in local.effective_tenants :
    tenant => {
      for key, instance in aws_instance.tenant :
      key => {
        id         = instance.id
        private_ip = instance.private_ip
        subnet_id  = instance.subnet_id
        class      = instance.tags["Class"]
      }
      if instance.tags["Tenant"] == tenant
    }
  }
}

# Instance IDs grouped by class (for patch targeting)
# Uses stable instance keys (e.g., "bravo-rocky-linux-0") as inner map keys
# so downstream for_each won't break when instance IDs are unknown at plan time
output "instances_by_class" {
  description = "Instances grouped by class name - map of class_name => { instance_key => instance_id }"
  value = {
    for class_name in distinct([for k, v in local.tenant_instances : v.class]) :
    class_name => {
      for k, v in local.tenant_instances :
      k => aws_instance.tenant[k].id
      if v.class == class_name
    }
  }
}

# EKS Clusters
output "eks_clusters" {
  description = "Deployed EKS clusters with metadata"
  value = {
    for key, cluster in aws_eks_cluster.cluster :
    key => {
      id                        = cluster.id
      arn                       = cluster.arn
      endpoint                  = cluster.endpoint
      cluster_security_group_id = cluster.vpc_config[0].cluster_security_group_id
      version                   = cluster.version
      status                    = cluster.status
    }
  }
}

# EKS Cluster Security Groups (simplified map for downstream modules)
output "eks_cluster_security_groups" {
  description = "EKS cluster security group IDs (map: class_name => security_group_id)"
  value = {
    for key, cluster in aws_eks_cluster.cluster :
    key => cluster.vpc_config[0].cluster_security_group_id
  }
}

# EKS Node Groups
output "eks_node_groups" {
  description = "Deployed EKS node groups with metadata"
  value = {
    for key, ng in aws_eks_node_group.node_group :
    key => {
      id             = ng.id
      arn            = ng.arn
      cluster_name   = ng.cluster_name
      status         = ng.status
      instance_types = ng.instance_types
      scaling_config = ng.scaling_config
    }
  }
}

# EKS Test Commands
output "eks_test_commands" {
  description = "Commands to test EKS cluster connectivity (kubeconfig managed automatically)"
  value = {
    for key, cluster in aws_eks_cluster.cluster :
    key => {
      context           = key
      verify_connection = "kubectl config use-context ${key} && kubectl cluster-info"
      check_nodes       = "kubectl config use-context ${key} && kubectl get nodes -o wide"
      check_pods        = "kubectl config use-context ${key} && kubectl get pods --all-namespaces"
      deploy_test_pod   = "kubectl config use-context ${key} && kubectl run test-nginx --image=nginx --restart=Never && kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s"
      cleanup_test_pod  = "kubectl config use-context ${key} && kubectl delete pod test-nginx"
    }
  }
}

# Application Requests (dependency inversion interface for applications module)
# Expands per tenant × class for SSM/Ansible applications (tenant-specific deployments)
# Expands per class only for user-data/Helm applications (class-level deployments)
output "application_requests" {
  description = "Application installation requests for applications module"
  value       = local.application_requests
}

# Cluster Application Requests (separate output - does NOT feed back to compute)
# For mode = "1-master" classes: per-instance Ansible requests with NODE_RANK / NUM_NODES /
# MASTER_ADDR / MASTER_PORT injected. These reference aws_instance.tenant.private_ip and
# therefore CANNOT be included in application_requests (which returns to compute via
# applications module, creating a dependency cycle). They flow:
#   compute -> applications (separate input) -> configuration-management only.
output "cluster_application_requests" {
  description = "Per-instance cluster application requests for mode: 1-master classes (not fed back to compute)"
  value       = local.cluster_application_requests
}

# IAM Role ARN (pass-through from access module)
output "instance_role_arn" {
  description = "IAM role ARN for compute instances (for S3 bucket policy)"
  value       = lookup(var.access_iam_role_arns, "compute-instance", "")
}

# IAM Role Name (pass-through from access module)
output "instance_role_name" {
  description = "IAM role name for compute instances (for attaching policies)"
  value       = lookup(var.access_iam_role_names, "compute-instance", "")
}

# EKS Node Role Name (dependency inversion interface for EKS-based modules)
output "eks_node_role_name" {
  description = "EKS node group IAM role name (for attaching policies)"
  value       = length(aws_iam_role.eks_node_group) > 0 ? values(aws_iam_role.eks_node_group)[0].name : ""
}

# ALB FQDNs for HTTPS EC2 instances (per-instance host-based routing)
output "alb_dns_names" {
  description = "Map of instance_key to FQDN for HTTPS ALB instances"
  value = {
    for instance_key, instance in local.https_instances :
    instance_key => instance.fqdn
  }
}

# Terraform-Managed NLB DNS Names (dependency inversion return path)
output "lb_dns_names" {
  description = "NLB DNS names for EKS services (keyed by cluster_class-name)"
  value = {
    for key, lb in aws_lb.eks_service :
    key => lb.dns_name
  }
}

# Note: Single-cluster outputs removed - Helm now uses CLI-based deployment
# This supports dynamic number of clusters without provider limitations

# Helm Release Deployments (CLI-based)
output "helm_releases" {
  description = "Deployed Helm releases with metadata and access commands"
  value = {
    for k, v in null_resource.helm_release : k => {
      release_name         = v.triggers.release_name
      chart                = v.triggers.chart
      version              = v.triggers.version
      namespace            = v.triggers.namespace
      cluster_name         = v.triggers.cluster_name
      context              = v.triggers.context
      check_status         = "helm status ${v.triggers.release_name} -n ${v.triggers.namespace} --kube-context ${v.triggers.context}"
      get_services         = "kubectl get svc -n ${v.triggers.namespace} --context ${v.triggers.context}"
      get_loadbalancer_url = "kubectl get svc -n ${v.triggers.namespace} --context ${v.triggers.context} -o json | jq -r '.items[] | select(.spec.type==\"LoadBalancer\") | .status.loadBalancer.ingress[0].hostname // .status.loadBalancer.ingress[0].ip // \"pending\"'"
      get_all_resources    = "kubectl get all -n ${v.triggers.namespace} --context ${v.triggers.context}"
    }
  }
}

# Command Registry
# Standardized operational commands for terminal output and portal self-service actions
output "commands" {
  description = "Standardized operational commands for CLI display and portal actions"
  value = concat(
    # EKS cluster commands
    flatten([
      for key, cluster in aws_eks_cluster.cluster : [
        {
          title       = "Verify EKS Connection: ${key}"
          description = "Verify connectivity to EKS cluster ${key}"
          commands    = ["kubectl config use-context ${key} && kubectl cluster-info"]
          service     = "compute"
          category    = "eks-verify"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            context = key
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "Check EKS Nodes: ${key}"
          description = "List nodes in EKS cluster ${key}"
          commands    = ["kubectl config use-context ${key} && kubectl get nodes -o wide"]
          service     = "compute"
          category    = "eks-nodes"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            context = key
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "Check EKS Pods: ${key}"
          description = "List all pods in EKS cluster ${key}"
          commands    = ["kubectl config use-context ${key} && kubectl get pods --all-namespaces"]
          service     = "compute"
          category    = "eks-pods"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            context = key
            region  = data.aws_region.current.id
          }
        }
      ]
    ]),
    # ECS cluster commands
    flatten([
      for key, cluster in aws_ecs_cluster.cluster : [
        {
          title       = "ECS Cluster Health: ${key}"
          description = "Show service health overview for cluster ${cluster.name} - shows which services are healthy vs unhealthy"
          commands    = ["AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs describe-services --cluster ${cluster.name} --services $(aws ecs list-services --cluster ${cluster.name} --query 'serviceArns' --output text) --query 'services[].{Service:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' --output table 2>/dev/null || echo 'No services in cluster'"]
          service     = "compute"
          category    = "ecs-health"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            cluster = cluster.name
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "ECS Recent Failures: ${key}"
          description = "Show recently stopped tasks and why they failed in cluster ${cluster.name}"
          commands    = ["AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs describe-tasks --cluster ${cluster.name} --tasks $(aws ecs list-tasks --cluster ${cluster.name} --desired-status STOPPED --query 'taskArns[0:10]' --output text) --query 'tasks[].{Task:taskArn,Service:group,StoppedAt:stoppedAt,Reason:stoppedReason,ExitCode:containers[0].exitCode}' --output table 2>/dev/null || echo 'No stopped tasks found'"]
          service     = "compute"
          category    = "ecs-failures"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            cluster = cluster.name
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "List ECS Services: ${key}"
          description = "List all services in ECS cluster ${cluster.name}"
          commands    = ["AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs list-services --cluster ${cluster.name}"]
          service     = "compute"
          category    = "ecs-services"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            cluster = cluster.name
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "List ECS Tasks: ${key}"
          description = "List running tasks (containers) in ECS cluster ${cluster.name}"
          commands    = ["AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs list-tasks --cluster ${cluster.name}"]
          service     = "compute"
          category    = "ecs-tasks"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            cluster = cluster.name
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "List Stopped ECS Tasks: ${key}"
          description = "List recently stopped task ARNs in ECS cluster ${cluster.name}"
          commands    = ["AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs list-tasks --cluster ${cluster.name} --desired-status STOPPED"]
          service     = "compute"
          category    = "ecs-stopped"
          target_type = "cluster"
          target      = key
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            cluster = cluster.name
            region  = data.aws_region.current.id
          }
        },
      ]
    ]),
    # Helm release commands
    flatten([
      for k, v in null_resource.helm_release : [
        {
          title       = "Helm Status: ${v.triggers.release_name}"
          description = "Check Helm release status for ${v.triggers.release_name} in ${v.triggers.namespace}"
          commands    = ["helm status ${v.triggers.release_name} -n ${v.triggers.namespace} --kube-context ${v.triggers.context}"]
          service     = "compute"
          category    = "helm-status"
          target_type = "cluster"
          target      = v.triggers.context
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            context = v.triggers.context
            region  = data.aws_region.current.id
          }
        },
        {
          title       = "Helm Services: ${v.triggers.release_name}"
          description = "List services for ${v.triggers.release_name} in ${v.triggers.namespace}"
          commands    = ["kubectl get svc -n ${v.triggers.namespace} --context ${v.triggers.context}"]
          service     = "compute"
          category    = "helm-services"
          target_type = "cluster"
          target      = v.triggers.context
          execution   = "local"
          action_config = {
            type    = "cli_exec"
            context = v.triggers.context
            region  = data.aws_region.current.id
          }
        }
      ]
    ]),
    # EC2 instance taint commands (one per class; instance resolved at runtime from entity title)
    [
      for class_name in keys(local.ec2_classes) : {
        title       = "Taint Instance"
        description = "Mark an EC2 instance as tainted. It will be destroyed and recreated on next terraform apply."
        commands    = []
        service     = "compute"
        category    = "instance-taint"
        target_type = "instance"
        target      = class_name
        execution   = "local"
        action_config = {
          type                      = "state_taint"
          resource_address_template = "module.compute[0].aws_instance.tenant[\"{{INSTANCE_KEY}}\"]"
          workspace                 = terraform.workspace
          region                    = data.aws_region.current.id
        }
      }
      if length(lookup(var.tenants_by_class, class_name, [])) > 0
    ],
    # EKS cluster taint commands (one per cluster; cluster resolved at runtime from entity title)
    [
      for key, cluster in aws_eks_cluster.cluster : {
        title       = "Taint Cluster"
        description = "Mark a cluster as tainted. It will be destroyed and recreated on next terraform apply."
        commands    = []
        service     = "compute"
        category    = "cluster-taint"
        target_type = "cluster"
        target      = key
        execution   = "local"
        action_config = {
          type                      = "state_taint"
          resource_address_template = "module.compute[0].aws_eks_cluster.cluster[\"{{INSTANCE_KEY}}\"]"
          workspace                 = terraform.workspace
          region                    = data.aws_region.current.id
        }
      }
    ],
    # ECS cluster taint commands (one per cluster; cluster resolved at runtime from entity title)
    [
      for key, cluster in aws_ecs_cluster.cluster : {
        title       = "Taint Cluster"
        description = "Mark a cluster as tainted. It will be destroyed and recreated on next terraform apply."
        commands    = []
        service     = "compute"
        category    = "cluster-taint"
        target_type = "cluster"
        target      = key
        execution   = "local"
        action_config = {
          type                      = "state_taint"
          resource_address_template = "module.compute[0].aws_ecs_cluster.cluster[\"{{INSTANCE_KEY}}\"]"
          workspace                 = terraform.workspace
          region                    = data.aws_region.current.id
        }
      }
    ]
  )
}

# Kubeconfig Dependency (for cross-module dependencies)
# Other modules can depend on this to ensure kubeconfig is set up before kubectl operations
output "kubeconfig_ready" {
  description = "Dependency marker indicating kubeconfig contexts are set up"
  value = {
    for k, v in null_resource.kubeconfig_manager : k => {
      context = k
      ready   = true
    }
  }
}

# ECS Clusters
output "ecs_clusters" {
  description = "Deployed ECS clusters with metadata"
  value = {
    for key, cluster in aws_ecs_cluster.cluster :
    key => {
      id   = cluster.id
      arn  = cluster.arn
      name = cluster.name
    }
  }
}

# Access requests (dependency inversion interface for access module)
# Access module creates IAM resources from these requests and returns ARNs/names
output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value = local.has_applications ? [
    {
      module              = "compute"
      type                = "iam-role"
      purpose             = "instance"
      description         = "EC2 instance role for compute classes with applications"
      trust_services      = ["ec2.amazonaws.com"]
      trust_roles         = []
      trust_actions       = ["sts:AssumeRole"]
      trust_conditions    = "{}"
      managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
      inline_policies     = {}
      instance_profile    = true
    }
  ] : []
}

# Access: Security Groups (dependency inversion interface for access module)
output "access_security_groups" {
  description = "Security groups with rules for the access module (AWS-native format)"
  value       = local.access_security_groups
}

# ECS Test Commands
output "ecs_test_commands" {
  description = "Commands to debug ECS clusters, services, and tasks"
  value = {
    for key, cluster in aws_ecs_cluster.cluster :
    key => {
      cluster_name    = cluster.name
      health_overview = "AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs describe-services --cluster ${cluster.name} --services $(aws ecs list-services --cluster ${cluster.name} --query 'serviceArns' --output text) --query 'services[].{Service:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' --output table 2>/dev/null || echo 'No services'"
      recent_failures = "AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs describe-tasks --cluster ${cluster.name} --tasks $(aws ecs list-tasks --cluster ${cluster.name} --desired-status STOPPED --query 'taskArns[0:10]' --output text) --query 'tasks[].{Service:group,StoppedAt:stoppedAt,Reason:stoppedReason,Exit:containers[0].exitCode}' --output table 2>/dev/null || echo 'No stopped tasks'"
      list_services   = "AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs list-services --cluster ${cluster.name}"
      list_tasks      = "AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs list-tasks --cluster ${cluster.name}"
      stopped_tasks   = "AWS_PROFILE=${var.aws_profile} AWS_REGION=${data.aws_region.current.id} aws ecs list-tasks --cluster ${cluster.name} --desired-status STOPPED"
    }
  }
}
