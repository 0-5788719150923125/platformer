packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "region" {
  type    = string
  default = "${region}"
}

# Query base AMI metadata for OS detection
data "amazon-ami" "base" {
  filters = {
    image-id = "${base_ami}"
  }
  owners = ["self", "amazon", "aws-marketplace"]
  region = var.region
}

locals {
  # Detect OS from AMI name
  is_windows    = length(regexall("(?i)windows", data.amazon-ami.base.name)) > 0
  platform_type = local.is_windows ? "windows" : "linux"

  # Infer SSH username from AMI name  -  each distro uses a different default user
  ssh_username = (
    local.is_windows ? "Administrator" :
    length(regexall("(?i)ubuntu|deep.learning.*ubuntu", data.amazon-ami.base.name)) > 0 ? "ubuntu" :
    length(regexall("(?i)debian", data.amazon-ami.base.name)) > 0 ? "admin" :
    length(regexall("(?i)rocky", data.amazon-ami.base.name)) > 0 ? "rocky" :
    length(regexall("(?i)centos", data.amazon-ami.base.name)) > 0 ? "centos" :
    "ec2-user"
  )

  # Infer root device name from AMI name
  # Ubuntu/Debian/Deep Learning AMIs use /dev/sda1; Amazon Linux / generic use /dev/xvda
  root_device_name = (
    length(regexall("(?i)ubuntu|debian|deep.learning", data.amazon-ami.base.name)) > 0
    ? "/dev/sda1"
    : "/dev/xvda"
  )
}

source "amazon-ebs" "golden_ami" {
  ami_name      = "${class_name}-${namespace}-{{timestamp}}"
  instance_type = "${instance_type}"
  region        = var.region
  source_ami    = "${base_ami}"

  # VPC targeting - Packer will create temporary security group automatically
  vpc_id    = "${vpc_id}"
  subnet_id = "${subnet_id}"

  # SSM communicator (matches production execution path)
  # Public IP needed so instance can reach SSM endpoints over internet
  communicator                = "ssh"
  ssh_interface               = "session_manager"
  ssh_username                = local.ssh_username
  associate_public_ip_address = true
  ssh_timeout                 = "15m"

  # IAM instance profile for SSM + Secrets Manager
  iam_instance_profile = "${instance_profile}"

  # Extended polling timeouts for large AMI snapshots (200GB volumes with CUDA/PyTorch
  # can take 30-60 minutes to snapshot; default ~10 min polling window is insufficient)
  aws_polling {
    delay_seconds = 30
    max_attempts  = 180  # 180 * 30s = 90 minutes
  }

  # Root volume configuration
  # Use the inferred root device name  -  Ubuntu/Deep Learning AMIs use /dev/sda1 while
  # Amazon Linux uses /dev/xvda. Using the wrong name attaches a second volume and leaves
  # the actual root at its default size, causing out-of-space errors during large builds.
  launch_block_device_mappings {
    device_name           = local.root_device_name
    volume_size           = ${volume_size}
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # AMI tags
  tags = merge(
    {
      Name        = "${class_name}"
      Class       = "${class_name}"
      Namespace   = "${namespace}"
      BuiltBy     = "Packer"
      ContentHash = "${content_hash}"
      BuildTime   = "{{timestamp}}"
    },
%{ for k, v in ami_tags ~}
    { "${k}" = "${v}" },
%{ endfor ~}
  )
}

build {
  sources = ["source.amazon-ebs.golden_ami"]

  # ========== OS Updates ==========
%{ if is_windows ~}
  provisioner "powershell" {
    inline = [
      "Write-Host 'Applying Windows updates...'",
      "Install-Module PSWindowsUpdate -Force -SkipPublisherCheck",
      "Import-Module PSWindowsUpdate",
      "Install-WindowsUpdate -AcceptAll -IgnoreReboot"
    ]
  }
%{ else ~}
  provisioner "shell" {
    inline = [
      "echo 'Applying OS updates...'",
      "if command -v dnf >/dev/null 2>&1; then sudo dnf update -y; elif command -v yum >/dev/null 2>&1; then sudo yum update -y; elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get upgrade -y; fi"
    ]
  }
%{ endif ~}

  # ========== Script Applications ==========
%{ for idx, app in script_apps ~}
%{ if is_windows ~}
  provisioner "powershell" {
%{ if length(try(app.params, {})) > 0 ~}
    env = {
%{ for k, v in try(app.params, {}) ~}
      ${k} = "${v}"
%{ endfor ~}
    }
%{ endif ~}
    script = "${app.script_path}"
  }
%{ else ~}
  provisioner "shell" {
%{ if length(try(app.params, {})) > 0 ~}
    environment_vars = [
%{ for k, v in try(app.params, {}) ~}
      "${k}=${v}",
%{ endfor ~}
    ]
%{ endif ~}
    script = "${app.script_path}"
  }
%{ endif ~}
%{ endfor ~}

  # ========== Ansible Applications ==========
%{ for idx, app in ansible_apps ~}
  provisioner "ansible" {
    playbook_file = "${app.playbook_path}"

    # Use ansible-playbook from venv (has boto3 installed)
    command = "${ansible_venv_path}/ansible-playbook"

    extra_arguments = [
%{ for k, v in try(app.params, {}) ~}
      "-e", "${k}=${v}",
%{ endfor ~}
      "-e", "AWS_REGION=${region}",
      "-e", "DEPLOYMENT_NAMESPACE=${namespace}",
%{ if application_scripts_bucket != "" ~}
      "-e", "ANSIBLE_PLAYBOOKS_BUCKET=${application_scripts_bucket}",
%{ endif ~}
      "-l", local.platform_type,  # Target correct host group (linux/windows)
    ]

    # Inventory template - only define host in the appropriate OS group
    inventory_file_template = <<-EOT
      ${inventory_template}
    EOT

    use_proxy = true
  }
%{ endfor ~}

  # ========== Pre-snapshot cleanup ==========
  # Remove pip/package cache to reduce snapshot size and speed up AMI creation.
  # Services remain enabled (auto-start on production boot) but should not be running
  # during snapshot - an active GPU workload slows instance stop and snapshot time.
%{ if !is_windows ~}
  provisioner "shell" {
    inline = [
      "sudo pip cache purge 2>/dev/null || true",
      "if command -v dnf >/dev/null 2>&1; then sudo dnf clean all; elif command -v yum >/dev/null 2>&1; then sudo yum clean all; elif command -v apt-get >/dev/null 2>&1; then sudo apt-get clean; fi",
      "sudo rm -rf /tmp/*.tar.gz /tmp/*.whl",
      "sync"
    ]
  }
%{ endif ~}

  # ========== Create manifest ==========
  post-processor "manifest" {
    output     = "${terraform_root}/build/output/${class_name}-${content_hash}-manifest.json"
    strip_path = true
  }
}
