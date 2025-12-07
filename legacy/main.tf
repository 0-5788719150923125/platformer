# Legacy Atlantis EC2 Instance
# Disposable, cattle-style EC2 instance with Atlantis pre-built in AMI

# Fetch consolidated Atlantis secrets (GitHub App key, webhook secret)
data "aws_secretsmanager_secret_version" "atlantis_secrets" {
  provider  = aws.prod
  secret_id = "arn:aws:secretsmanager:us-east-2:111111111111:secret:dev/atlantis-635cKP"
}

# Fetch GitHub personal access token (for cloning infra-docker during Packer build)
data "aws_secretsmanager_secret_version" "github_token" {
  provider  = aws.prod
  secret_id = "arn:aws:secretsmanager:us-east-2:111111111111:secret:prod/pltawporthook/github_token-g4rxkF"
}

# Parse the JSON secret and define constants
locals {
  atlantis_secrets      = jsondecode(data.aws_secretsmanager_secret_version.atlantis_secrets.secret_string)
  atlantis_web_username = "admin"
}

# Generate random password for Atlantis web UI
resource "random_password" "atlantis_web_password" {
  length  = 32
  special = true
}

# Build Atlantis AMI using Packer
# Clones infra-docker directly and builds the Docker image
resource "null_resource" "build_atlantis_ami" {
  # Instance profile is created by access module (passed via variables)

  triggers = {
    # Rebuild if any of these change
    source_branch   = "PROJ-5045-research-implement-local-admin-password-rotation-for-windows"
    namespace       = var.namespace
    packer_template = filemd5("${path.module}/packer/atlantis.pkr.hcl")
    atlantis_port   = var.config.atlantis_port
    start_script    = filemd5("${path.module}/packer/scripts/start-atlantis.sh")
    test_script     = filemd5("${path.module}/packer/scripts/test-atlantis.sh")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      set -o pipefail
      cd ${path.module}/packer

      echo "Building Atlantis AMI with Packer..."
      packer init atlantis.pkr.hcl

      echo "Starting Packer build - this will fail the deployment if unsuccessful..."
      packer build \
        -var "region=${data.aws_region.current.id}" \
        -var "github_token=${nonsensitive(data.aws_secretsmanager_secret_version.github_token.secret_string)}" \
        -var "git_branch=PROJ-5045-research-implement-local-admin-password-rotation-for-windows" \
        -var "atlantis_port=${var.config.atlantis_port}" \
        -var "atlantis_repo_allowlist=${join(",", var.config.atlantis_repo_allowlist)}" \
        -var "namespace=${var.namespace}" \
        -var "iam_instance_profile=${var.access_instance_profile_names["legacy-atlantis-instance"]}" \
        atlantis.pkr.hcl

      echo "AMI build complete successfully!"
    EOT

    on_failure = fail
  }
}

# EC2 instance for Atlantis
# Uses custom AMI built by Packer with Atlantis pre-installed
resource "aws_instance" "atlantis" {
  depends_on = [
    null_resource.build_atlantis_ami # Wait for Packer to build the AMI
  ]

  ami                    = data.aws_ami.atlantis.id
  instance_type          = var.config.instance_type
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [aws_security_group.atlantis_instance.id]
  iam_instance_profile   = var.access_instance_profile_names["legacy-atlantis-instance"]

  # Public IP (optional, for testing)
  associate_public_ip_address = var.config.enable_public_ip

  # Root volume configuration
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.config.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "atlantis-legacy-root-${var.namespace}"
    }
  }

  # Pass consolidated secrets JSON, web credentials at deploy time
  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap.sh", {
    atlantis_secrets_json = data.aws_secretsmanager_secret_version.atlantis_secrets.secret_string
    web_username          = local.atlantis_web_username
    web_password          = random_password.atlantis_web_password.result
  }))

  user_data_replace_on_change = true

  tags = {
    Name        = "atlantis-legacy-${var.namespace}"
    Service     = "atlantis"
    Environment = "legacy"
    ManagedBy   = "terraform-packer"
    AMI         = data.aws_ami.atlantis.id
  }

  lifecycle {
    create_before_destroy = false
  }
}
