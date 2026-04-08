# Load Balancers for Compute Resources
# - NLBs: EKS services (dependency inversion from upstream modules)
# - ALBs: EC2 HTTPS classes (TLS termination with ACM certificates)

# ============================================================================
# NLBs for EKS Services (dependency inversion)
# ============================================================================
# Upstream modules emit lb_requests; compute creates NLBs with target groups
# pointing at EKS node group ASGs via static NodePorts. This keeps AWS
# infrastructure in Terraform state (no orphaned LBs on destroy).

locals {
  # Filter lb_requests to EKS classes that actually exist in config
  lb_request_map = {
    for req in var.lb_requests :
    "${req.cluster_class}-${req.name}" => req
    if contains(keys(local.eks_classes), req.cluster_class)
  }

  # Expand lb_requests × node_groups for ASG attachment (config-driven, plan-time safe keys)
  lb_asg_attachments = merge([
    for lb_key, req in local.lb_request_map : {
      for ng_key in flatten([
        for class_name, class_config in local.eks_classes :
        [for ng_name in keys(coalesce(class_config.node_groups, {})) : "${class_name}-${ng_name}"]
        if class_name == req.cluster_class
      ]) :
      "${lb_key}--${ng_key}" => {
        lb_key = lb_key
        ng_key = ng_key
      }
    }
  ]...)
}

resource "aws_lb" "eks_service" {
  for_each = local.lb_request_map

  name               = substr("${var.namespace}-${each.value.name}", 0, 32)
  internal           = each.value.internal
  load_balancer_type = "network"
  subnets            = local.eks_cluster_subnets[each.value.cluster_class]

  tags = {
    Name      = "${var.namespace}-${each.value.name}"
    Namespace = var.namespace
    Class     = each.value.cluster_class
    Service   = each.value.name
  }
}

resource "aws_lb_target_group" "eks_service" {
  for_each = local.lb_request_map

  name        = substr("${var.namespace}-${each.value.name}", 0, 32)
  port        = each.value.node_port
  protocol    = each.value.protocol
  vpc_id      = local.class_networks[each.value.cluster_class] != null ? local.class_networks[each.value.cluster_class].network_summary.vpc_id : var.networks["default"].network_summary.vpc_id
  target_type = "instance"

  dynamic "health_check" {
    for_each = each.value.health_check_path != null ? [1] : []
    content {
      protocol            = "HTTP"
      path                = each.value.health_check_path
      port                = tostring(each.value.node_port)
      healthy_threshold   = 3
      unhealthy_threshold = 3
      interval            = 30
    }
  }

  dynamic "health_check" {
    for_each = each.value.health_check_path == null ? [1] : []
    content {
      protocol            = "TCP"
      port                = tostring(each.value.node_port)
      healthy_threshold   = 3
      unhealthy_threshold = 3
      interval            = 30
    }
  }

  tags = {
    Name      = "${var.namespace}-${each.value.name}"
    Namespace = var.namespace
  }
}

resource "aws_lb_listener" "eks_service" {
  for_each = local.lb_request_map

  load_balancer_arn = aws_lb.eks_service[each.key].arn
  port              = each.value.port
  protocol          = each.value.protocol

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks_service[each.key].arn
  }
}

resource "aws_autoscaling_attachment" "eks_service" {
  for_each = local.lb_asg_attachments

  autoscaling_group_name = aws_eks_node_group.node_group[each.value.ng_key].resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.eks_service[each.value.lb_key].arn
}

# Security group rule: allow NLB traffic to NodePorts on EKS nodes
# NLBs pass through client IPs, so we allow from 0.0.0.0/0 on the NodePort
resource "aws_security_group_rule" "nlb_to_nodeport" {
  for_each = local.lb_request_map

  type              = "ingress"
  from_port         = each.value.node_port
  to_port           = each.value.node_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_eks_cluster.cluster[each.value.cluster_class].vpc_config[0].cluster_security_group_id
  description       = "NLB traffic to ${each.value.name} NodePort"
}

# ============================================================================
# ALBs for EC2 HTTPS Classes (per-instance host-based routing)
# ============================================================================
# One shared ALB per class, with per-instance target groups and host-based
# listener rules. Each instance gets its own DNS name:
#   {instance_key}.{zone_name}  (e.g., test-praxis-dev-0.dev-platform.example.com)
#
# TLS terminates at the ALB; backend traffic to instances uses HTTP on the original port.

# ── Locals ──────────────────────────────────────────────────────────
locals {
  # Public subnet resolution: internet-facing ALBs require public subnets in at least 2 AZs
  alb_subnets = {
    for class_name, _ in local.https_classes : class_name => (
      local.class_networks[class_name] != null
      ? local.class_networks[class_name].subnets_by_tier["public"].ids
      : var.networks["default"].subnets_by_tier["public"].ids
    )
  }

  # Per-instance entries for HTTPS classes (target groups, listener rules, DNS records)
  https_instances = merge([
    for class_name, https_class in local.https_classes : {
      for instance_key, instance_config in local.tenant_instances :
      instance_key => {
        class_name   = class_name
        instance_key = instance_key
        port         = https_class.https_rules[0].port
        fqdn         = "${instance_key}.${var.domain_zone_name}"
        # Start at 100 to leave room for alias rules (priority 1-99)
        priority     = index(sort([for k, v in local.tenant_instances : k if v.class == class_name]), instance_key) + 100
      }
      if instance_config.class == class_name
    }
  ]...)
}

# ── ALB Security Group ──────────────────────────────────────────────
# Allows 443 + 80 (redirect) from configured CIDRs
resource "aws_security_group" "alb" {
  for_each = local.https_classes

  name_prefix = "${var.namespace}-${each.key}-alb-"
  description = "ALB security group for ${each.key} HTTPS ingress"
  vpc_id      = local.class_vpc_ids[each.key]

  # HTTPS ingress from configured CIDRs
  dynamic "ingress" {
    for_each = each.value.https_rules
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidrs
      description = "HTTPS from configured CIDRs (backend port ${ingress.value.port})"
    }
  }

  # HTTP ingress for redirect (same CIDRs as HTTPS)
  dynamic "ingress" {
    for_each = each.value.https_rules
    content {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidrs
      description = "HTTP redirect to HTTPS"
    }
  }

  # Egress: Allow all outbound (health checks + forwarding to instances)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name      = "${var.namespace}-${each.key}-alb"
    Class     = each.key
    Namespace = var.namespace
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Instance SG Rule: Allow ALB → Instance on Backend Port ──────────
resource "aws_security_group_rule" "instance_ingress_from_alb" {
  for_each = local.https_classes

  type                     = "ingress"
  from_port                = each.value.https_rules[0].port
  to_port                  = each.value.https_rules[0].port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb[each.key].id
  security_group_id        = aws_security_group.class[each.key].id
  description              = "Allow ALB to reach backend port ${each.value.https_rules[0].port}"
}

# ── Application Load Balancer (one per class, shared) ────────────────
resource "aws_lb" "ec2_https" {
  for_each = local.https_classes

  name               = substr("${var.namespace}-${each.key}", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[each.key].id]
  subnets            = local.alb_subnets[each.key]

  tags = {
    Name      = "${var.namespace}-${each.key}-alb"
    Class     = each.key
    Namespace = var.namespace
  }
}

# ── Per-Instance Target Groups ──────────────────────────────────────
# Each instance gets its own target group so host-based routing can
# direct traffic to a specific instance.
resource "aws_lb_target_group" "ec2_https" {
  for_each = local.https_instances

  name        = substr("${var.namespace}-${each.key}", 0, 32)
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = local.class_vpc_ids[each.value.class_name]
  target_type = "instance"

  health_check {
    protocol            = "HTTP"
    port                = tostring(each.value.port)
    path                = "/"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = {
    Name      = "${var.namespace}-${each.key}-tg"
    Class     = each.value.class_name
    Namespace = var.namespace
  }
}

# ── Per-Instance Target Group Attachment ─────────────────────────────
resource "aws_lb_target_group_attachment" "ec2_https" {
  for_each = local.https_instances

  target_group_arn = aws_lb_target_group.ec2_https[each.key].arn
  target_id        = aws_instance.tenant[each.key].id
  port             = each.value.port
}

# ── HTTPS Listener (default action: 404 - all traffic routed by rules) ──
resource "aws_lb_listener" "ec2_https" {
  for_each = local.https_classes

  load_balancer_arn = aws_lb.ec2_https[each.key].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.domain_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Unknown host"
      status_code  = "404"
    }
  }
}

# ── Per-Instance Listener Rules (host-header routing) ────────────────
# Each instance's FQDN routes to its dedicated target group
resource "aws_lb_listener_rule" "ec2_https" {
  for_each = local.https_instances

  listener_arn = aws_lb_listener.ec2_https[each.value.class_name].arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_https[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.fqdn]
    }
  }
}

# ── Alias Listener Rules (host-header routing for custom domain aliases) ──
# Routes alias FQDNs to the same target group as instance-0
resource "aws_lb_listener_rule" "ec2_alias" {
  for_each = { for fqdn, r in local.alias_records : fqdn => r if r.is_https }

  listener_arn = aws_lb_listener.ec2_https[each.value.class_name].arn
  priority     = 1 # Aliases get highest priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_https[each.value.instance_key].arn
  }

  condition {
    host_header {
      values = [each.value.fqdn]
    }
  }
}

# ── HTTP Listener (80 → redirect to HTTPS) ──────────────────────────
resource "aws_lb_listener" "ec2_http_redirect" {
  for_each = local.https_classes

  load_balancer_arn = aws_lb.ec2_https[each.key].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── Per-Instance Route53 A Records ───────────────────────────────────
# Each instance gets its own DNS name pointing to the shared class ALB.
# Host-header routing at the ALB directs to the correct instance.
resource "aws_route53_record" "ec2_https" {
  for_each = local.https_instances

  zone_id = var.domain_zone_id
  name    = each.value.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.ec2_https[each.value.class_name].dns_name
    zone_id                = aws_lb.ec2_https[each.value.class_name].zone_id
    evaluate_target_health = true
  }
}

# ── Per-Instance Route53 A Records (HTTP classes) ────────────────────
# When a domain is configured but the class uses protocol: http (no ALB),
# create A records pointing directly at the EC2 public IP.
locals {
  http_instances_with_domain = var.domain_enabled ? merge([
    for class_name, class_config in local.ec2_classes : {
      for instance_key, instance_config in local.tenant_instances :
      instance_key => {
        class_name   = class_name
        instance_key = instance_key
        port         = [for rule in coalesce(class_config.ingress, []) : rule.port if rule.protocol == "http"][0]
        fqdn         = "${instance_key}.${var.domain_zone_name}"
      }
      if instance_config.class == class_name
    }
    # Only HTTP-only classes (not already handled by HTTPS ALB records)
    if length([for rule in coalesce(class_config.ingress, []) : rule if rule.protocol == "http"]) > 0
    && !contains(keys(local.https_classes), class_name)
  ]...) : {}
}

resource "aws_route53_record" "ec2_http" {
  for_each = local.http_instances_with_domain

  zone_id = var.domain_zone_id
  name    = each.value.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_instance.tenant[each.key].public_ip]
}

# ── Custom DNS Aliases ──────────────────────────────────────────────
# User-defined aliases (services.domains.aliases) that map FQDNs to compute classes.
# Resolves to the first entitled tenant's instance-0 of the target class.
# HTTPS classes: ALIAS record to the class ALB.
# HTTP classes: A record to the EC2 public IP.
locals {
  # Resolve each alias to the instance key of instance-0 for the first entitled tenant
  alias_records = {
    for fqdn, class_name in var.domain_aliases : fqdn => {
      fqdn         = fqdn
      class_name   = class_name
      instance_key = "${lookup(var.tenants_by_class, class_name, [""])[0]}-${class_name}-0"
      is_https     = contains(keys(local.https_classes), class_name)
    }
    if contains(keys(local.ec2_classes), class_name)
  }
}

resource "aws_route53_record" "alias_https" {
  for_each = { for fqdn, r in local.alias_records : fqdn => r if r.is_https }

  zone_id = var.domain_zone_id
  name    = each.value.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.ec2_https[each.value.class_name].dns_name
    zone_id                = aws_lb.ec2_https[each.value.class_name].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "alias_http" {
  for_each = { for fqdn, r in local.alias_records : fqdn => r if !r.is_https }

  zone_id = var.domain_zone_id
  name    = each.value.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_instance.tenant[each.value.instance_key].public_ip]
}
