# Shared security group for Maestro SSH trust between PACS nodes
# Maestro's orchestrator-runner model requires bidirectional SSH on port 22.
# A single self-referencing security group is shared across all compute classes
# in a deployment, so any PACS instance can SSH to any other.

resource "aws_security_group" "maestro_ssh" {
  for_each = local.maestro_deployments

  name_prefix = "${var.namespace}-${each.key}-maestro-ssh-"
  description = "Allow SSH between PACS nodes for Maestro (${each.key})"
  vpc_id      = local.network_by_deployment[each.key].network_summary.vpc_id

  tags = {
    Name       = "${var.namespace}-${each.key}-maestro-ssh"
    Namespace  = var.namespace
    Deployment = each.key
    ManagedBy  = "platformer-archpacs"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "maestro_ssh_ingress" {
  for_each = local.maestro_deployments

  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.maestro_ssh[each.key].id
  source_security_group_id = aws_security_group.maestro_ssh[each.key].id
  description              = "Allow SSH between Maestro PACS nodes"
}

locals {
  access_security_groups = [
    for deploy_name, sg in aws_security_group.maestro_ssh : {
      module      = "archpacs"
      group_name  = sg.name
      description = sg.description
      ingress = [
        {
          description           = "SSH between PACS nodes for Maestro"
          protocol              = "tcp"
          from_port             = 22
          to_port               = 22
          cidr_blocks           = []
          source_security_group = ""
          self                  = true
        }
      ]
      egress = []
    }
  ]
}
