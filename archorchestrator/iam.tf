# ArchOrchestrator IAM
# IAM roles are created by the access module via access_requests (dependency inversion).
# All values in access_requests are config/variable-derived (no module-internal resource
# attributes) to avoid Terraform module-closure cycles.

locals {
  access_requests = [
    # ECS Task Execution Role - pulls images, writes logs
    {
      module              = "archorchestrator"
      type                = "iam-role"
      purpose             = "ecs-execution"
      description         = "ECS task execution role (pull images, write logs)"
      trust_services      = ["ecs-tasks.amazonaws.com"]
      trust_roles         = []
      trust_actions       = ["sts:AssumeRole"]
      trust_conditions    = "{}"
      managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
      inline_policies     = {} # ECR inline policy stays local below (references aws_ecr_repository.main.arn)
      instance_profile    = false
    },
    # ECS Task Role - runtime application permissions
    {
      module              = "archorchestrator"
      type                = "iam-role"
      purpose             = "ecs-task"
      description         = "ECS task role (runtime application permissions)"
      trust_services      = ["ecs-tasks.amazonaws.com"]
      trust_roles         = []
      trust_actions       = ["sts:AssumeRole"]
      trust_conditions    = "{}"
      managed_policy_arns = []
      instance_profile    = false
      inline_policies = {
        "archorchestrator-app-access" = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Sid    = "S3BucketAccess"
              Effect = "Allow"
              Action = [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
              ]
              Resource = flatten([
                for purpose, bucket_name in var.s3_buckets : [
                  "arn:aws:s3:::${bucket_name}",
                  "arn:aws:s3:::${bucket_name}/*",
                ]
              ])
            },
            {
              Sid    = "SSMParameterAccess"
              Effect = "Allow"
              Action = [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath",
              ]
              Resource = [
                "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.namespace}/archorchestrator/*",
                "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/clario/*",
              ]
            },
            {
              Sid    = "CloudWatchLogs"
              Effect = "Allow"
              Action = [
                "logs:CreateLogStream",
                "logs:PutLogEvents",
              ]
              Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ecs/${var.namespace}/*"
            },
            {
              Sid    = "ServiceDiscovery"
              Effect = "Allow"
              Action = [
                "servicediscovery:DiscoverInstances"
              ]
              Resource = "*"
            },
            {
              Sid    = "STSAssumeRole"
              Effect = "Allow"
              Action = [
                "sts:AssumeRole",
                "sts:SetSourceIdentity"
              ]
              Resource = [
                "arn:aws:iam::${var.aws_account_id}:role/${var.namespace}-archorchestrator-ecs-bootstrap",
                "arn:aws:iam::${var.aws_account_id}:role/${var.namespace}-archorchestrator-ecs-app"
              ]
            }
          ]
        })
      }
    },
    # ECS Bootstrap Role - Clario credential isolation (assumed by task role)
    {
      module              = "archorchestrator"
      type                = "iam-role"
      purpose             = "ecs-bootstrap"
      description         = "ECS bootstrap role (Clario credential isolation)"
      trust_services      = []
      trust_roles         = ["archorchestrator-ecs-task"]
      trust_actions       = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      trust_conditions    = "{}"
      managed_policy_arns = []
      instance_profile    = false
      inline_policies = {
        "bootstrap-ssm-access" = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Sid    = "SSMParameterAccess"
              Effect = "Allow"
              Action = [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath",
              ]
              Resource = [
                "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.namespace}/archorchestrator/*",
                "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/clario/*",
              ]
            }
          ]
        })
      }
    },
    # ECS Application Role - runtime operations (assumed by task role with source identity)
    {
      module              = "archorchestrator"
      type                = "iam-role"
      purpose             = "ecs-app"
      description         = "ECS application role (S3, Secrets Manager, EventBridge, Bedrock)"
      trust_services      = []
      trust_roles         = ["archorchestrator-ecs-task"]
      trust_actions       = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      managed_policy_arns = []
      instance_profile    = false
      trust_conditions = jsonencode({
        StringEquals = {
          "sts:SourceIdentity" = "clario-app-5259d757-1477-4786-ad8c-a498cba80499"
        }
      })
      inline_policies = {
        "app-runtime-access" = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Sid    = "S3BucketAccess"
              Effect = "Allow"
              Action = [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
              ]
              Resource = flatten([
                for purpose, bucket_name in var.s3_buckets : [
                  "arn:aws:s3:::${bucket_name}",
                  "arn:aws:s3:::${bucket_name}/*",
                ]
              ])
            },
            {
              Sid    = "SecretsManagerAccess"
              Effect = "Allow"
              Action = [
                "secretsmanager:GetSecretValue",
              ]
              Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:/clario/*"
            },
            {
              Sid    = "SSMParameterAccess"
              Effect = "Allow"
              Action = [
                "ssm:GetParameter",
                "ssm:PutParameter",
                "ssm:DeleteParameter",
              ]
              Resource = [
                "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/clario-app/*",
              ]
            },
            {
              Sid    = "EventBridgeScheduler"
              Effect = "Allow"
              Action = [
                "scheduler:CreateSchedule",
                "scheduler:CreateScheduleGroup",
                "scheduler:TagResource",
                "iam:PassRole",
              ]
              Resource = "*"
            },
            {
              Sid    = "TranscribeAccess"
              Effect = "Allow"
              Action = [
                "transcribe:StartMedicalStreamTranscription*",
              ]
              Resource = "*"
            },
            {
              Sid    = "BedrockAccess"
              Effect = "Allow"
              Action = [
                "bedrock:InvokeModel*",
              ]
              Resource = "*"
            }
          ]
        })
      }
    }
  ]
}

# ── Local ECR Pull Policy ──────────────────────────────────────────────────
# Must stay local: references aws_ecr_repository.main.arn (module-internal resource)
# Attached to the access-created execution role

resource "aws_iam_role_policy" "ecs_execution_ecr" {
  name = "ecr-local-pull"
  role = var.access_iam_role_names["archorchestrator-ecs-execution"]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.main.arn
      },
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      }
    ]
  })
}
