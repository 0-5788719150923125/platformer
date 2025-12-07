# Instance Information
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.atlantis.id
}

output "instance_arn" {
  description = "EC2 instance ARN"
  value       = aws_instance.atlantis.arn
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = aws_instance.atlantis.private_ip
}

output "instance_private_dns" {
  description = "Private DNS name of the instance"
  value       = aws_instance.atlantis.private_dns
}

output "instance_public_ip" {
  description = "Public IP address of the instance (if enabled)"
  value       = aws_instance.atlantis.public_ip
}

output "instance_public_dns" {
  description = "Public DNS name of the instance (if enabled)"
  value       = aws_instance.atlantis.public_dns
}

# Atlantis Information
output "atlantis_url" {
  description = "Atlantis UI URL (use public DNS)"
  value       = "http://${aws_instance.atlantis.public_dns}:${var.config.atlantis_port}"
}

output "atlantis_web_username" {
  description = "Atlantis web UI username"
  value       = local.atlantis_web_username
}

output "atlantis_web_password" {
  description = "Atlantis web UI password (auto-generated)"
  value       = nonsensitive(random_password.atlantis_web_password.result)
}

output "atlantis_image" {
  description = "Atlantis container image used"
  value       = "local-atlantis:latest (baked into AMI)"
}

output "ami_id" {
  description = "AMI ID used for this instance (built by Packer)"
  value       = data.aws_ami.atlantis.id
}

output "ami_name" {
  description = "AMI name used for this instance"
  value       = data.aws_ami.atlantis.name
}

# S3 Build Archive
# S3 resources removed - Packer clones directly from GitHub

# Security Group
output "security_group_id" {
  description = "Security group ID for the Atlantis instance"
  value       = aws_security_group.atlantis_instance.id
}

# IAM (managed by access module via access_requests)
output "iam_role_name" {
  description = "IAM role name for the instance"
  value       = var.access_iam_role_names["legacy-atlantis-instance"]
}

output "iam_role_arn" {
  description = "IAM role ARN for the instance"
  value       = var.access_iam_role_arns["legacy-atlantis-instance"]
}

output "iam_instance_profile_name" {
  description = "IAM instance profile name"
  value       = var.access_instance_profile_names["legacy-atlantis-instance"]
}

# Access: IAM access requests (dependency inversion - access creates IAM resources)
output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value = [
    {
      module              = "legacy"
      type                = "iam-role"
      purpose             = "atlantis-instance"
      description         = "IAM role for legacy Atlantis EC2 instance (AdministratorAccess)"
      trust_services      = ["ec2.amazonaws.com"]
      trust_roles         = []
      trust_actions       = ["sts:AssumeRole"]
      trust_conditions    = "{}"
      managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", "arn:aws:iam::aws:policy/AdministratorAccess"]
      inline_policies     = {}
      instance_profile    = true
    }
  ]
}

# Useful Commands
output "ssm_connect_command" {
  description = "AWS CLI command to connect via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.atlantis.id}"
}

output "systemd_logs_command" {
  description = "Command to view Atlantis systemd service logs via SSM"
  value       = "aws ssm start-session --target ${aws_instance.atlantis.id} --document-name AWS-StartInteractiveCommand --parameters command='sudo journalctl -u atlantis -f'"
}

output "container_logs_command" {
  description = "Command to view Atlantis container logs via SSM"
  value       = "aws ssm start-session --target ${aws_instance.atlantis.id} --document-name AWS-StartInteractiveCommand --parameters command='sudo docker logs atlantis --tail 100 -f'"
}

output "container_status_command" {
  description = "Command to check Atlantis container status via SSM"
  value       = "aws ssm start-session --target ${aws_instance.atlantis.id} --document-name AWS-StartInteractiveCommand --parameters command='sudo docker ps -a --filter name=atlantis'"
}
