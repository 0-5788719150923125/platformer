# ArchOrchestrator Module
# Domain orchestration for ArchOrchestrator (IO Cloud / SaaSApp) deployments
# Provisions ECS Fargate services with ALB, Cloud Map service discovery, and SSM parameters
# Generates infrastructure requests (RDS, S3, ECS clusters) via dependency inversion
# ECS clusters are provided by compute module through dependency inversion

# ── CloudWatch Log Groups (per service) ──────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs" {
  for_each = local.ecs_services

  name              = "/ecs/${var.namespace}/io/${replace(each.key, "/", "-")}"
  retention_in_days = 30

  tags = {
    Namespace  = var.namespace
    Deployment = each.value.deployment
    Service    = each.value.service
    ManagedBy  = "platformer-archorchestrator"
  }
}

# ── Cloud Map Service Discovery (per deployment) ────────────────────────────
# Enables inter-service discovery (e.g., router → saasapp.io.local)

resource "aws_service_discovery_private_dns_namespace" "main" {
  for_each = var.config

  name = "${each.key}.io.local"
  vpc  = local.network_by_deployment[each.key].network_summary.vpc_id

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

resource "aws_service_discovery_service" "ecs" {
  for_each = local.ecs_services

  name = each.value.service

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main[each.value.deployment].id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

# ── ECS Task Definitions (per service) ──────────────────────────────────────

resource "aws_ecs_task_definition" "main" {
  for_each = local.ecs_services

  family                   = "${var.namespace}-${replace(each.key, "/", "-")}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = var.access_iam_role_arns["archorchestrator-ecs-execution"]
  task_role_arn            = var.access_iam_role_arns["archorchestrator-ecs-task"]

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = each.value.architecture
  }

  container_definitions = jsonencode([
    {
      name      = each.value.service
      image     = local.container_images[each.key]
      cpu       = each.value.cpu
      memory    = each.value.memory
      essential = true

      portMappings = [
        {
          containerPort = each.value.port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs[each.key].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = each.value.service
        }
      }

      environment = concat(
        [
          { name = "DEPLOYMENT_NAME", value = each.value.deployment },
          { name = "SERVICE_NAME", value = each.value.service },
          { name = "NAMESPACE", value = var.namespace },
          { name = "BOOTSTRAP_AWS_REGION", value = var.aws_region },
          { name = "BOOTSTRAP_INSTANCEID", value = each.value.deployment },
        ],
        # SaaSApp-specific: bootstrap role ARN for credential isolation
        each.value.service == "saasapp" ? [
          { name = "BOOTSTRAP_AWS_ASSUME_ROLE_ARN", value = var.access_iam_role_arns["archorchestrator-ecs-bootstrap"] }
        ] : [],
        [for k, v in each.value.environment : { name = k, value = v }]
      )
    }
  ])

  tags = {
    Namespace  = var.namespace
    Deployment = each.value.deployment
    Service    = each.value.service
    ManagedBy  = "platformer-archorchestrator"
  }

  depends_on = [null_resource.ecr_replicate]
}

# ── ECS Services (per service) ───────────────────────────────────────────────

resource "aws_ecs_service" "main" {
  for_each = local.ecs_services

  name            = each.value.service
  cluster         = var.ecs_clusters["${each.value.deployment}-io"].id
  task_definition = aws_ecs_task_definition.main[each.key].arn
  desired_count   = each.value.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.network_by_deployment[each.value.deployment].subnets_by_tier.private.ids
    security_groups  = [aws_security_group.ecs[each.value.deployment].id]
    assign_public_ip = true # Required: default VPC has no NAT gateway for private subnet egress
  }

  # Only router is exposed via ALB; saasapp and coreapps use service discovery only
  dynamic "load_balancer" {
    for_each = each.value.service == "router" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.ecs[each.key].arn
      container_name   = each.value.service
      container_port   = each.value.port
    }
  }

  service_registries {
    registry_arn = aws_service_discovery_service.ecs[each.key].arn
  }

  depends_on = [aws_lb_listener.http]

  tags = {
    Namespace  = var.namespace
    Deployment = each.value.deployment
    Service    = each.value.service
    ManagedBy  = "platformer-archorchestrator"
  }
}

# ── Application Load Balancer (per deployment) ──────────────────────────────
# HTTP only for now — HTTPS via ACM can be added when DNS is configured

resource "aws_lb" "main" {
  for_each = var.config

  name               = "${var.namespace}-${each.key}-io"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[each.key].id]
  subnets            = local.network_by_deployment[each.key].subnets_by_tier.public.ids

  tags = {
    Name       = "${var.namespace}-${each.key}-io"
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# Target groups (only for router - other services use service discovery only)
resource "aws_lb_target_group" "ecs" {
  for_each = {
    for key, svc in local.ecs_services : key => svc
    if svc.service == "router"
  }

  name        = substr("${var.namespace}-${replace(each.key, "/", "-")}", 0, 32)
  port        = each.value.port
  protocol    = each.value.protocol
  vpc_id      = local.network_by_deployment[each.value.deployment].network_summary.vpc_id
  target_type = "ip" # Required for Fargate awsvpc

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = each.value.protocol
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = {
    Namespace  = var.namespace
    Deployment = each.value.deployment
    Service    = each.value.service
    ManagedBy  = "platformer-archorchestrator"
  }

}

# HTTP listener — default action forwards to the first service (router)
# Additional path-based rules route to specific services
resource "aws_lb_listener" "http" {
  for_each = var.config

  load_balancer_arn = aws_lb.main[each.key].arn
  port              = 80
  protocol          = "HTTP"

  # Default: forward to router (if it exists), otherwise first service
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs["${each.key}/${contains(keys(each.value.ecs), "router") ? "router" : keys(each.value.ecs)[0]}"].arn
  }

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# No listener rules needed - router is the only service exposed via ALB (default action)
# SaaSApp and CoreApps are accessed internally via service discovery only

# ── SSM Parameters (deployment context) ─────────────────────────────────────
# Connection strings and bucket names for application configuration

resource "aws_ssm_parameter" "deployment_context" {
  for_each = var.config

  name = "/${var.namespace}/archorchestrator/${each.key}/deployment-context"
  type = "String"
  value = jsonencode({
    deployment = each.key
    namespace  = var.namespace
    alb_url    = "http://${aws_lb.main[each.key].dns_name}"
    rds = try({
      endpoint = var.rds_instances["${each.key}-mssql"].endpoint
      port     = var.rds_instances["${each.key}-mssql"].port
    }, null)
    s3_buckets = {
      for bucket_cfg in each.value.s3 :
      bucket_cfg.purpose => try(var.s3_buckets["${each.key}-${bucket_cfg.purpose}"], "")
    }
  })

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# ── Application SSM Parameters (legacy paths) ────────────────────────────────
# SaaSApp/CoreApps applications read configuration from hardcoded SSM paths
# under /saasapp/{deployment}/properties/*. We seed required parameters here.

resource "random_password" "jwt_key" {
  for_each = var.config
  length   = 64
  special  = false
}

resource "aws_ssm_parameter" "internal_jwt_key" {
  for_each = var.config

  name  = "/saasapp/${each.key}/properties/internal-jwt-key"
  type  = "SecureString"
  value = random_password.jwt_key[each.key].result

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "application_role_arn" {
  for_each = var.config

  name  = "/saasapp/${each.key}/properties/application-role-arn"
  type  = "String"
  value = var.access_iam_role_arns["archorchestrator-ecs-app"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# WebSocket endpoint for real-time communication
resource "aws_ssm_parameter" "wss_endpoint" {
  for_each = var.config

  name  = "/saasapp/${each.key}/properties/wss-endpoint"
  type  = "String"
  value = "wss://${aws_lb.main[each.key].dns_name}/ws"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# Service connectivity configuration (cell-based)
# SaaSApp expects connectivity configuration under /saasapp/{deployment}/cell/{cell_id}/properties/
# Cell ID is set via BOOTSTRAP_CELL_ID environment variable (default: "default")
resource "aws_ssm_parameter" "connectivity_coreapps" {
  for_each = var.config

  name  = "/saasapp/${each.key}/cell/default/properties/connectivity.internal.coreapps.base-url"
  type  = "String"
  value = "http://coreapps.${each.key}.io.local:17000"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

resource "aws_ssm_parameter" "connectivity_control_plane" {
  for_each = var.config

  name  = "/saasapp/${each.key}/cell/default/properties/connectivity.internal.control-plane.base-url"
  type  = "String"
  value = "http://saasapp.${each.key}.io.local:30000"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

resource "aws_ssm_parameter" "connectivity_internal_api" {
  for_each = var.config

  name  = "/saasapp/${each.key}/cell/default/properties/connectivity.internal.internal-api.base-url"
  type  = "String"
  value = "http://saasapp.${each.key}.io.local:30000"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# AWS resource mappings - S3 buckets for tenant data, messaging, and configuration
# Path format: /saasapp/${instanceId}/aws-resources/{scope}/{type}/{identifier}
# Scope "app" is used for application-level resources
resource "aws_ssm_parameter" "aws_resource_s3_tenant" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/s3/tenant"
  type  = "String"
  value = var.s3_buckets["${each.key}-documents"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

resource "aws_ssm_parameter" "aws_resource_s3_messaging" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/s3/messaging"
  type  = "String"
  value = var.s3_buckets["${each.key}-messaging"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

resource "aws_ssm_parameter" "aws_resource_s3_configuration" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/s3/configuration"
  type  = "String"
  value = var.s3_buckets["${each.key}-configuration"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# Additional S3 buckets required by SaaSApp application
resource "aws_ssm_parameter" "aws_resource_s3_documents" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/s3/documents"
  type  = "String"
  value = var.s3_buckets["${each.key}-documents"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

resource "aws_ssm_parameter" "aws_resource_s3_download" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/s3/download"
  type  = "String"
  value = var.s3_buckets["${each.key}-configuration"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

# CloudWatch log group reference
resource "aws_ssm_parameter" "aws_resource_log_group" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/log-group/app-logs"
  type  = "String"
  value = "/ecs/${var.namespace}/io/${each.key}-saasapp"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}

# DynamoDB tables (placeholders - replace with real tables when needed)
resource "aws_ssm_parameter" "aws_resource_dynamodb_gateway" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/dynamodb/gateway"
  type  = "String"
  value = "placeholder-gateway-table"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

resource "aws_ssm_parameter" "aws_resource_dynamodb_job_lock" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/dynamodb/job-lock"
  type  = "String"
  value = "placeholder-job-lock-table"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

# Lambda function (placeholder - replace with real function when needed)
resource "aws_ssm_parameter" "aws_resource_lambda_job_dispatch" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/lambda/job-dispatch-lambda-arn"
  type  = "String"
  value = "arn:aws:lambda:${var.aws_region}:${var.aws_account_id}:function:placeholder-job-dispatch"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

# IAM role for Lambda (reusing existing app role)
resource "aws_ssm_parameter" "aws_resource_iam_job_dispatch_role" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/iam-role/job-dispatch-lambda-role-arn"
  type  = "String"
  value = var.access_iam_role_arns["archorchestrator-ecs-app"]

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

# SES email resources (placeholders - replace with real SES configuration when needed)
resource "aws_ssm_parameter" "aws_resource_ses_domain" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/ses/domain"
  type  = "String"
  value = "mail.${each.key}.example.com"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

resource "aws_ssm_parameter" "aws_resource_ses_identity" {
  for_each = var.config

  name  = "/saasapp/${each.key}/aws-resources/app/ses/identity-arn"
  type  = "String"
  value = "arn:aws:ses:${var.aws_region}:${var.aws_account_id}:identity/${each.key}.example.com"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
    Phase      = "placeholder"
  }
}

# ── S3 Bucket Requests (dependency inversion) ───────────────────────────────

locals {
  bucket_requests = flatten([
    for deploy_name, config in var.config : [
      for bucket_config in config.s3 : {
        purpose        = "${deploy_name}-${bucket_config.purpose}"
        description    = "ArchOrchestrator ${bucket_config.purpose} for ${deploy_name}"
        prefix         = "io-${var.namespace}"
        lifecycle_days = bucket_config.lifecycle_days
        force_destroy  = true
      }
    ]
  ])
}

# ── RDS Cluster Requests (dependency inversion) ─────────────────────────────
# SQL Server standalone instances (type = "standalone")

locals {
  rds_cluster_requests = [
    for deploy_name, config in var.config : {
      purpose                    = "${deploy_name}-mssql"
      type                       = "standalone"
      name                       = "${var.namespace}-${deploy_name}-io-mssql"
      engine                     = config.rds.engine
      engine_version             = config.rds.engine_version
      instance_class             = config.rds.instance_class
      allocated_storage          = config.rds.allocated_storage
      storage_type               = config.rds.storage_type
      multi_az                   = config.rds.multi_az
      deletion_protection        = config.rds.deletion_protection
      backup_retention_period    = config.rds.backup_retention_period
      subnet_ids                 = local.network_by_deployment[deploy_name].subnets_by_tier.private.ids
      vpc_id                     = local.network_by_deployment[deploy_name].network_summary.vpc_id
      allowed_security_group_ids = [aws_security_group.ecs[deploy_name].id]
    } if config.rds != null
  ]
}
# ── S3 Configuration Files ───────────────────────────────────────────────────
# Upload required configuration files to S3 buckets

# Router tenant mapping JSON (per deployment)
# Maps tenant codes to their tenant configuration
# Generates deterministic UUIDs based on namespace + deployment + tenant for stable tenant IDs
locals {
  tenant_mappings = {
    for deploy_name, tenants in var.tenants_by_deployment : deploy_name => jsonencode([
      for tenant in tenants : {
        state   = "active"
        version = try(var.config[deploy_name].ecs.saasapp.image, "unknown")
        id      = uuidv5("dns", "${var.namespace}.${deploy_name}.${tenant}")
        code    = tenant
      }
    ])
  }
}

resource "aws_s3_object" "tenant_mapping" {
  for_each = local.tenant_mappings

  bucket       = var.s3_buckets["${each.key}-configuration"]
  key          = "router/tenant-mapping.json"
  content      = each.value
  content_type = "application/json"

  tags = {
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }
}
