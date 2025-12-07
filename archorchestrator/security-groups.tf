# ArchOrchestrator Security Groups
# ALB ingress, ECS service communication, and ECS → RDS access

# ── ALB Security Group (per deployment) ──────────────────────────────────────
# Allows inbound HTTP from anywhere (HTTPS via ACM can be added later)

resource "aws_security_group" "alb" {
  for_each = var.config

  name_prefix = "${var.namespace}-${each.key}-io-alb-"
  description = "ArchOrchestrator ALB for ${each.key}"
  vpc_id      = local.network_by_deployment[each.key].network_summary.vpc_id

  tags = {
    Name       = "${var.namespace}-${each.key}-io-alb"
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "alb_ingress_http" {
  for_each = var.config

  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb[each.key].id
  description       = "HTTP from anywhere"
}

resource "aws_security_group_rule" "alb_egress" {
  for_each = var.config

  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb[each.key].id
  description       = "Allow all outbound"
}

# ── ECS Service Security Group (per deployment) ─────────────────────────────
# Allows ALB → ECS traffic on service ports, plus inter-service communication

resource "aws_security_group" "ecs" {
  for_each = var.config

  name_prefix = "${var.namespace}-${each.key}-io-ecs-"
  description = "ArchOrchestrator ECS services for ${each.key}"
  vpc_id      = local.network_by_deployment[each.key].network_summary.vpc_id

  tags = {
    Name       = "${var.namespace}-${each.key}-io-ecs"
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archorchestrator"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ALB → ECS: allow traffic from ALB on all service ports
resource "aws_security_group_rule" "ecs_ingress_from_alb" {
  for_each = var.config

  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb[each.key].id
  security_group_id        = aws_security_group.ecs[each.key].id
  description              = "All TCP from ALB"
}

# Inter-service: ECS tasks can communicate with each other (via Cloud Map)
resource "aws_security_group_rule" "ecs_ingress_self" {
  for_each = var.config

  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs[each.key].id
  security_group_id        = aws_security_group.ecs[each.key].id
  description              = "Inter-service communication"
}

resource "aws_security_group_rule" "ecs_egress" {
  for_each = var.config

  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ecs[each.key].id
  description       = "Allow all outbound (ECR pull, S3, SSM, etc.)"
}

# Note: ECS → RDS access rules are handled by the storage module via
# allowed_security_group_ids in rds_instance_requests (dependency inversion pattern)

locals {
  access_security_groups = concat(
    # ALB security groups (per deployment)
    [
      for deploy_name, sg in aws_security_group.alb : {
        module      = "archorchestrator"
        group_name  = sg.name
        description = sg.description
        ingress = [
          {
            description           = "HTTP from anywhere"
            protocol              = "tcp"
            from_port             = 80
            to_port               = 80
            cidr_blocks           = ["0.0.0.0/0"]
            source_security_group = ""
            self                  = false
          }
        ]
        egress = [{
          description = "Allow all outbound"
          protocol    = "-1"
          from_port   = 0
          to_port     = 0
          cidr_blocks = ["0.0.0.0/0"]
        }]
      }
    ],
    # ECS security groups (per deployment)
    [
      for deploy_name, sg in aws_security_group.ecs : {
        module      = "archorchestrator"
        group_name  = sg.name
        description = sg.description
        ingress = [
          {
            description           = "All TCP from ALB"
            protocol              = "tcp"
            from_port             = 0
            to_port               = 65535
            cidr_blocks           = []
            source_security_group = aws_security_group.alb[deploy_name].id
            self                  = false
          },
          {
            description           = "Inter-service communication"
            protocol              = "tcp"
            from_port             = 0
            to_port               = 65535
            cidr_blocks           = []
            source_security_group = ""
            self                  = true
          }
        ]
        egress = [{
          description = "Allow all outbound (ECR pull, S3, SSM)"
          protocol    = "-1"
          from_port   = 0
          to_port     = 0
          cidr_blocks = ["0.0.0.0/0"]
        }]
      }
    ],
  )
}
