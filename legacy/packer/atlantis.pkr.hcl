packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "github_token" {
  type        = string
  description = "GitHub token for cloning infra-docker repository"
  sensitive   = true
}

variable "git_branch" {
  type        = string
  description = "Branch to clone from infra-docker"
  default     = "PROJ-5045-research-implement-local-admin-password-rotation-for-windows"
}

variable "atlantis_port" {
  type    = number
  default = 80
}

variable "atlantis_repo_allowlist" {
  type    = string
  default = "github.com/acme-org/infra-terraform"
}

variable "namespace" {
  type        = string
  description = "Deployment namespace for tagging"
}

variable "iam_instance_profile" {
  type        = string
  description = "IAM instance profile name for S3 access"
}

# Find latest Amazon Linux 2023 AMI
data "amazon-ami" "al2023" {
  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    architecture        = "x86_64"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["amazon"]
  region      = var.region
}

source "amazon-ebs" "atlantis" {
  ami_name             = "atlantis-legacy-${var.namespace}-{{timestamp}}"
  instance_type        = "m6i.2xlarge" # 8 vCPU, 32GB RAM - Fast Docker builds
  region               = var.region
  source_ami           = data.amazon-ami.al2023.id
  ssh_username         = "ec2-user"
  iam_instance_profile = var.iam_instance_profile

  tags = {
    Name        = "atlantis-legacy-${var.namespace}"
    Service     = "atlantis"
    Environment = "legacy"
    ManagedBy   = "packer-terraform"
    BuildTime   = "{{timestamp}}"
  }
}

build {
  sources = ["source.amazon-ebs.atlantis"]

  # Install git and Docker
  provisioner "shell" {
    inline = [
      "echo 'Installing git and Docker...'",
      "sudo yum update -y",
      "sudo yum install -y git docker",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "sudo usermod -aG docker ec2-user"
    ]
  }

  # Clone infra-docker repo and extract Atlantis build
  provisioner "shell" {
    inline = [
      "echo 'Cloning infra-docker repository...'",
      "git clone -b ${var.git_branch} https://${var.github_token}@github.com/acme-org/infra-docker.git /tmp/infra-docker",
      "echo 'Extracting Atlantis build directory...'",
      "sudo mkdir -p /opt/atlantis-build",
      "sudo cp -r /tmp/infra-docker/environment/production/platform/atlantis/* /opt/atlantis-build/",
      "sudo chown -R ec2-user:ec2-user /opt/atlantis-build",
      "echo 'Cleaning up clone...'",
      "rm -rf /tmp/infra-docker"
    ]
  }

  # Build Atlantis Docker image using Austin's Dockerfile
  # Skip build.sh since it requires ECR access - just build the Dockerfile directly
  provisioner "shell" {
    inline = [
      "echo 'Building Atlantis Docker image...'",
      "cd /opt/atlantis-build",
      "if [ -f Dockerfile ]; then",
      "  sudo docker build -t local-atlantis:latest .",
      "  echo 'Docker image built successfully'",
      "  sudo docker images | grep atlantis",
      "else",
      "  echo 'ERROR: No Dockerfile found'",
      "  exit 1",
      "fi"
    ]
  }

  # Create Atlantis data directory with correct permissions
  provisioner "shell" {
    inline = [
      "echo 'Creating Atlantis data directory...'",
      "sudo mkdir -p /opt/atlantis/data",
      "sudo chown -R 100:1000 /opt/atlantis/data",
      "echo 'Creating secrets directory...'",
      "sudo mkdir -p /etc/atlantis"
    ]
  }

  # Copy repos.yaml into the build (will be copied to /etc/atlantis by bootstrap.sh)
  provisioner "file" {
    source      = "${path.root}/../repos.yaml"
    destination = "/tmp/repos.yaml"
  }

  provisioner "shell" {
    inline = [
      "echo 'Installing repos.yaml...'",
      "sudo mv /tmp/repos.yaml /opt/atlantis-build/repos.yaml",
      "sudo chown ec2-user:ec2-user /opt/atlantis-build/repos.yaml"
    ]
  }

  # Install Atlantis startup wrapper script
  provisioner "file" {
    source      = "${path.root}/scripts/start-atlantis.sh"
    destination = "/tmp/start-atlantis.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/start-atlantis.sh /usr/local/bin/start-atlantis.sh",
      "sudo chmod +x /usr/local/bin/start-atlantis.sh"
    ]
  }

  # Create systemd service for Atlantis
  provisioner "file" {
    content = templatefile("${path.root}/atlantis.service.tpl", {
      atlantis_port           = var.atlantis_port
      atlantis_repo_allowlist = var.atlantis_repo_allowlist
      region                  = var.region
    })
    destination = "/tmp/atlantis.service"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/atlantis.service /etc/systemd/system/atlantis.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable atlantis"
    ]
  }

  # Install health check script
  provisioner "file" {
    source      = "${path.root}/scripts/atlantis-health-check.sh"
    destination = "/tmp/atlantis-health-check.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/atlantis-health-check.sh /usr/local/bin/atlantis-health-check.sh",
      "sudo chmod +x /usr/local/bin/atlantis-health-check.sh"
    ]
  }

  # Test Atlantis installation (fail-fast validation)
  provisioner "file" {
    source      = "${path.root}/scripts/test-atlantis.sh"
    destination = "/tmp/test-atlantis.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/test-atlantis.sh",
      "/tmp/test-atlantis.sh ${var.atlantis_port}",
      "rm /tmp/test-atlantis.sh"
    ]
  }

  # Cleanup
  provisioner "shell" {
    inline = [
      "echo 'Cleaning up...'",
      "sudo rm -rf /tmp/*",
      "sudo yum clean all"
    ]
  }
}
