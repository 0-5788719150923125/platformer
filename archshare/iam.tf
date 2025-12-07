# Cross-account ECR permissions for Archshare instances
# Grants EC2 instances and EKS nodes permission to pull Docker images from legacy-tools account (777777777777)

# ECR policy definition (reused for both EC2 and EKS)
locals {
  ecr_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthorizationToken"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPullFromLegacyTools"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "arn:aws:ecr:*:777777777777:repository/*"
      }
    ]
  }
}

# EC2 instance role policy (for EC2-based deployments)
# Only attach if we have EC2 deployment-tenants
# Note: Relies on var.instance_role_name being provided by compute module
# If role doesn't exist, Terraform will error with clear message
resource "aws_iam_role_policy" "ecr_pull_ec2" {
  for_each = length(local.ec2_deployment_tenants) > 0 ? toset(["ec2"]) : toset([])

  name   = "${var.namespace}-archshare-ecr-pull-ec2"
  role   = var.instance_role_name
  policy = jsonencode(local.ecr_policy)
}

# EKS node role policy (for EKS-based deployments)
# Only attach if we have EKS deployment-tenants
# Note: Relies on var.eks_node_role_name being provided by compute module
# If role doesn't exist, Terraform will error with clear message
resource "aws_iam_role_policy" "ecr_pull_eks" {
  for_each = length(local.eks_deployment_tenants) > 0 ? toset(["eks"]) : toset([])

  name   = "${var.namespace}-archshare-ecr-pull-eks"
  role   = var.eks_node_role_name
  policy = jsonencode(local.ecr_policy)
}
