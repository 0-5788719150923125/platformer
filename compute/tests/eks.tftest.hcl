# Module-specific tests for EKS compute
# Tests EKS cluster creation, node group configuration, and IAM roles

run "eks_basic_cluster" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config = {
      test-eks = {
        type       = "eks"
        version    = "1.31"
        subnet_ids = ["subnet-abc123", "subnet-def456", "subnet-ghi789"]
        node_groups = {
          general = {
            instance_types = ["t3.small"]
            min_size       = 1
            max_size       = 2
            desired_size   = 1
            labels         = {}
            taints         = []
          }
        }
        endpoint_private_access = true
        endpoint_public_access  = false
        description             = "Test EKS cluster"
        tags                    = {}
      }
    }
    tenants_by_class = {
      test-eks = ["test-tenant"]
    }
  }

  # Verify EKS cluster is created
  assert {
    condition     = length(aws_eks_cluster.cluster) == 1
    error_message = "Should create exactly 1 EKS cluster"
  }

  # Verify cluster has correct version
  assert {
    condition     = aws_eks_cluster.cluster["test-eks"].version == "1.31"
    error_message = "Cluster should have K8s version 1.31"
  }

  # Verify VPC config
  assert {
    condition     = length(aws_eks_cluster.cluster["test-eks"].vpc_config[0].subnet_ids) == 3
    error_message = "Cluster should have 3 subnets"
  }

  # Verify endpoint access
  assert {
    condition     = aws_eks_cluster.cluster["test-eks"].vpc_config[0].endpoint_private_access == true
    error_message = "Private endpoint access should be enabled"
  }

  assert {
    condition     = aws_eks_cluster.cluster["test-eks"].vpc_config[0].endpoint_public_access == false
    error_message = "Public endpoint access should be disabled"
  }

  # Verify node group is created
  assert {
    condition     = length(aws_eks_node_group.node_group) == 1
    error_message = "Should create exactly 1 node group"
  }

  # Verify node group scaling config
  assert {
    condition     = aws_eks_node_group.node_group["test-eks-general"].scaling_config[0].desired_size == 1
    error_message = "Node group should have desired size of 1"
  }

  # Verify IAM roles are created
  assert {
    condition     = length(aws_iam_role.eks_cluster) == 1
    error_message = "Should create 1 cluster IAM role"
  }

  assert {
    condition     = length(aws_iam_role.eks_node_group) == 1
    error_message = "Should create 1 node group IAM role"
  }

  # Verify IAM policy attachments
  assert {
    condition     = length(aws_iam_role_policy_attachment.eks_cluster_policy) == 1
    error_message = "Should attach EKS cluster policy"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.eks_node_worker_policy) == 1
    error_message = "Should attach node worker policy"
  }
}

run "eks_multiple_node_groups" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config = {
      multi-ng = {
        type       = "eks"
        version    = "1.31"
        subnet_ids = ["subnet-abc123", "subnet-def456"]
        node_groups = {
          general = {
            instance_types = ["t3.small"]
            min_size       = 1
            max_size       = 3
            desired_size   = 2
            labels = {
              workload = "general"
            }
            taints = []
          }
          spot = {
            instance_types = ["t3.medium"]
            min_size       = 0
            max_size       = 5
            desired_size   = 1
            labels = {
              workload = "batch"
            }
            taints = [{
              key    = "spot"
              value  = "true"
              effect = "NO_SCHEDULE"
            }]
          }
        }
        endpoint_private_access = true
        endpoint_public_access  = true
        description             = ""
        tags                    = {}
      }
    }
    tenants_by_class = {
      multi-ng = ["test-tenant"]
    }
  }

  # Verify 1 cluster with 2 node groups
  assert {
    condition     = length(aws_eks_cluster.cluster) == 1
    error_message = "Should create exactly 1 EKS cluster"
  }

  assert {
    condition     = length(aws_eks_node_group.node_group) == 2
    error_message = "Should create exactly 2 node groups"
  }

  # Verify node group names
  assert {
    condition     = contains(keys(aws_eks_node_group.node_group), "multi-ng-general")
    error_message = "Should create 'general' node group"
  }

  assert {
    condition     = contains(keys(aws_eks_node_group.node_group), "multi-ng-spot")
    error_message = "Should create 'spot' node group"
  }

  # Verify node group labels
  assert {
    condition     = aws_eks_node_group.node_group["multi-ng-general"].labels["workload"] == "general"
    error_message = "General node group should have workload=general label"
  }

  assert {
    condition     = aws_eks_node_group.node_group["multi-ng-spot"].labels["workload"] == "batch"
    error_message = "Spot node group should have workload=batch label"
  }

  # Verify taints on spot node group
  assert {
    condition     = length(aws_eks_node_group.node_group["multi-ng-spot"].taint) == 1
    error_message = "Spot node group should have 1 taint"
  }
}

run "eks_empty_config" {
  command = plan

  variables {
    namespace      = "test-namespace"
    aws_account_id = "123456789012"
    config         = {}
  }

  # Verify no EKS resources created with empty config
  assert {
    condition     = length(aws_eks_cluster.cluster) == 0
    error_message = "Should not create EKS clusters with empty config"
  }

  assert {
    condition     = length(aws_eks_node_group.node_group) == 0
    error_message = "Should not create node groups with empty config"
  }

  # Verify outputs show empty state
  assert {
    condition     = length(output.eks_clusters) == 0
    error_message = "Should show no EKS clusters"
  }

  assert {
    condition     = length(output.eks_node_groups) == 0
    error_message = "Should show no node groups"
  }
}
