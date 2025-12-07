# Security groups for EC2 instances
# Created per-class for ingress control

# Default security group for each EC2 class (allows SSM, egress)
# Only created for classes with a resolvable VPC (explicit network or default network exists)
resource "aws_security_group" "class" {
  for_each = local.class_vpc_ids

  name_prefix = "${var.namespace}-${each.key}-"
  description = "Security group for ${each.key} instances"
  vpc_id      = each.value

  # Egress: Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name      = "${var.namespace}-${each.key}"
    Class     = each.key
    Namespace = var.namespace
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Intra-cluster ingress rule: allows all TCP traffic between nodes in the same class
# Uses a self-referencing SG rule (source = self) for same-class instance-to-instance traffic
# Required for distributed training (NCCL uses dynamic ports beyond the rendezvous port),
# Redis Cluster gossip, Kafka broker comms, etc.
resource "aws_security_group_rule" "cluster_intra" {
  for_each = {
    for class_name, class_config in local.ec2_classes :
    class_name => class_config
    if class_config.cluster_port != null && contains(keys(aws_security_group.class), class_name)
  }

  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.class[each.key].id
  security_group_id        = aws_security_group.class[each.key].id
  description              = "Allow all intra-cluster TCP traffic (cluster_port: ${each.value.cluster_port})"
}

# Ingress rules for HTTP access (protocol = "http" in normalized_ingress)
# HTTPS ingress is handled by ALB in alb.tf - these are direct SG rules only
# Key pattern preserved ("${class_name}-${port}") so existing state isn't disrupted
resource "aws_security_group_rule" "class_ingress" {
  for_each = local.http_ingress_rules

  type              = "ingress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = "tcp"
  cidr_blocks       = each.value.cidrs
  security_group_id = each.value.security_group_id
  description       = "Allow port ${each.value.port} from specified CIDRs"
}

locals {
  access_security_groups = concat(
    # Per EC2 class security groups
    [
      for class_name in keys(local.class_vpc_ids) : {
        module      = "compute"
        group_name  = aws_security_group.class[class_name].name
        description = "Security group for ${class_name} instances"
        ingress = concat(
          # Cluster intra-communication (if cluster_port set)
          try(local.ec2_classes[class_name].cluster_port, null) != null ? [{
            description           = "Intra-cluster TCP (cluster_port: ${local.ec2_classes[class_name].cluster_port})"
            protocol              = "tcp"
            from_port             = 0
            to_port               = 65535
            cidr_blocks           = []
            source_security_group = ""
            self                  = true
          }] : [],
          # HTTP ingress rules from CIDRs
          flatten([
            for rule in coalesce(try(local.ec2_classes[class_name].ingress, null), []) : [{
              description           = "Port ${rule.port} from configured CIDRs"
              protocol              = "tcp"
              from_port             = rule.port
              to_port               = rule.port
              cidr_blocks           = rule.cidrs
              source_security_group = ""
              self                  = false
            }]
            if rule.protocol == "http"
          ]),
          # ALB to instance backend port (for HTTPS classes)
          contains(keys(local.https_classes), class_name) ? [{
            description           = "ALB to backend port ${local.https_classes[class_name].https_rules[0].port}"
            protocol              = "tcp"
            from_port             = local.https_classes[class_name].https_rules[0].port
            to_port               = local.https_classes[class_name].https_rules[0].port
            cidr_blocks           = []
            source_security_group = aws_security_group.alb[class_name].id
            self                  = false
          }] : [],
        )
        egress = [{
          description = "Allow all outbound traffic"
          protocol    = "-1"
          from_port   = 0
          to_port     = 0
          cidr_blocks = ["0.0.0.0/0"]
        }]
      }
      if contains(keys(local.ec2_classes), class_name)
    ],
    # Per HTTPS class ALB security groups
    [
      for class_name, class_config in local.https_classes : {
        module      = "compute"
        group_name  = aws_security_group.alb[class_name].name
        description = "ALB security group for ${class_name} HTTPS ingress"
        ingress = flatten([
          for rule in class_config.https_rules : [
            {
              description           = "HTTPS (443) from configured CIDRs"
              protocol              = "tcp"
              from_port             = 443
              to_port               = 443
              cidr_blocks           = rule.cidrs
              source_security_group = ""
              self                  = false
            },
            {
              description           = "HTTP redirect (80) from configured CIDRs"
              protocol              = "tcp"
              from_port             = 80
              to_port               = 80
              cidr_blocks           = rule.cidrs
              source_security_group = ""
              self                  = false
            }
          ]
        ])
        egress = [{
          description = "Allow all outbound traffic"
          protocol    = "-1"
          from_port   = 0
          to_port     = 0
          cidr_blocks = ["0.0.0.0/0"]
        }]
      }
    ],
    # NLB to EKS NodePort rules (grouped by cluster class)
    [
      for req_class in distinct([for k, req in local.lb_request_map : req.cluster_class]) : {
        module      = "compute"
        group_name  = "${req_class}-eks-nlb-rules"
        description = "NLB NodePort rules added to EKS node security group"
        ingress = [
          for k, req in local.lb_request_map : {
            description           = "NLB to ${req.name} NodePort ${req.node_port}"
            protocol              = "tcp"
            from_port             = req.node_port
            to_port               = req.node_port
            cidr_blocks           = ["0.0.0.0/0"]
            source_security_group = ""
            self                  = false
          }
          if req.cluster_class == req_class
        ]
        egress = []
      }
    ],
  )
}
