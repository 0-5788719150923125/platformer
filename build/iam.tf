locals {
  has_builds = length(local.build_classes) > 0

  # IAM access requests for the access module (access creates resources, returns ARNs).
  # All values are config/variable-derived so Terraform can resolve this before the module closes.
  access_requests = local.has_builds ? [
    {
      module              = "build"
      type                = "iam-role"
      purpose             = "packer"
      description         = "Packer build instance role for golden AMI creation"
      trust_services      = ["ec2.amazonaws.com"]
      trust_roles         = []
      trust_actions       = ["sts:AssumeRole"]
      trust_conditions    = "{}"
      managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
      inline_policies = {
        "packer-permissions" = jsonencode({
          Version = "2012-10-17"
          Statement = concat(
            [
              {
                Sid    = "SecretsManagerAccess"
                Effect = "Allow"
                Action = [
                  "secretsmanager:GetSecretValue",
                  "secretsmanager:DescribeSecret"
                ]
                Resource = "arn:aws:secretsmanager:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:secret:platformer/${var.namespace}/*"
              },
              {
                Sid    = "SSMSessionBucketAccess"
                Effect = "Allow"
                Action = [
                  "s3:GetObject",
                  "s3:PutObject",
                  "s3:DeleteObject",
                  "s3:ListBucket",
                  "s3:GetBucketLocation"
                ]
                Resource = [
                  "arn:aws:s3:::aws-ssm-${data.aws_region.current.id}",
                  "arn:aws:s3:::aws-ssm-${data.aws_region.current.id}/*"
                ]
              },
              {
                Sid    = "SSMSessionAccess"
                Effect = "Allow"
                Action = [
                  "ssm:StartSession",
                  "ssm:TerminateSession",
                  "ssm:ResumeSession",
                  "ssm:DescribeInstanceInformation",
                  "ssm:GetConnectionStatus"
                ]
                Resource = "*"
              },
              {
                Sid      = "EC2Describe"
                Effect   = "Allow"
                Action   = ["ec2:DescribeInstances"]
                Resource = "*"
              }
            ],
            var.application_scripts_bucket != "" ? [
              {
                Sid    = "ApplicationScriptsBucketAccess"
                Effect = "Allow"
                Action = [
                  "s3:GetObject",
                  "s3:ListBucket"
                ]
                Resource = [
                  "arn:aws:s3:::${var.application_scripts_bucket}",
                  "arn:aws:s3:::${var.application_scripts_bucket}/*"
                ]
              }
            ] : []
          )
        })
      }
      instance_profile = true
    }
  ] : []
}
