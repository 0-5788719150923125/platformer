# IAM: Role, instance profile, and managed policy attachments are created by the
# access module via access_requests (dependency inversion). No local IAM resources.

# Security group for Atlantis EC2 instance
resource "aws_security_group" "atlantis_instance" {
  name        = "atlantis-legacy-${var.namespace}"
  description = "Security group for legacy Atlantis EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "atlantis-legacy-${var.namespace}"
  }
}

# Ingress: Atlantis UI (80/tcp) - open to all (it's a disposable test instance)
resource "aws_vpc_security_group_ingress_rule" "atlantis_ui" {
  security_group_id = aws_security_group.atlantis_instance.id
  description       = "Atlantis UI access"

  from_port   = var.config.atlantis_port
  to_port     = var.config.atlantis_port
  ip_protocol = "tcp"
  cidr_ipv4   = "0.0.0.0/0"

  tags = {
    Name = "atlantis-ui"
  }
}

# Ingress: SSH (22/tcp) - optional
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count             = var.config.enable_ssh ? 1 : 0
  security_group_id = aws_security_group.atlantis_instance.id
  description       = "SSH access"

  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
  cidr_ipv4   = "0.0.0.0/0"

  tags = {
    Name = "ssh"
  }
}

# Egress: Allow all outbound (for GitHub API, Docker pull, etc.)
resource "aws_vpc_security_group_egress_rule" "allow_all_outbound" {
  security_group_id = aws_security_group.atlantis_instance.id
  description       = "Allow all outbound traffic"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"

  tags = {
    Name = "allow-all-outbound"
  }
}
