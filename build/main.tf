# Build Module  -  Golden AMI builds for EC2 classes with build: true
# Extracted from compute module to break dependency cycles:
#   storage (creates bucket) → build (uploads archives, runs Packer) → compute (uses built AMIs)
# Build instances get direct S3 access to application-scripts bucket via IAM.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ============================================================================
# AMI Resolution (self-contained  -  avoids dependency cycle with compute)
# ============================================================================

# Strategy 1: SSM parameter lookup  -  only for build classes that specify ami_ssm_parameter
data "aws_ssm_parameter" "ami" {
  for_each = {
    for class_name, class_config in var.config : class_name => class_config
    if try(class_config.build, false) && try(class_config.type, "") == "ec2" && try(class_config.ami_ssm_parameter, null) != null
  }

  name = each.value.ami_ssm_parameter
}

# Strategy 2: AMI filter  -  only for build classes that use ami_filter (without ami_ssm_parameter)
data "aws_ami" "class" {
  for_each = {
    for class_name, class_config in var.config : class_name => class_config
    if try(class_config.build, false) && try(class_config.type, "") == "ec2" && try(class_config.ami_ssm_parameter, null) == null && try(class_config.ami_filter, null) != null
  }

  most_recent = true
  owners      = [coalesce(try(each.value.ami_owner, null), "amazon")]

  filter {
    name   = "name"
    values = [each.value.ami_filter]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  # Unified AMI ID map for build classes  -  SSM parameter wins when both are specified
  resolved_amis = merge(
    { for k, v in data.aws_ami.class : k => v.id },
    { for k, v in data.aws_ssm_parameter.ami : k => nonsensitive(v.value) },
  )

  # EC2 classes with build: true
  build_classes = {
    for class_name, class_config in var.config : class_name => class_config
    if try(class_config.build, false) && try(class_config.type, "") == "ec2"
  }

  # Standalone applications that should be included in each build class's golden AMI
  # Matching rules:
  #   wildcard → included in ALL build classes
  #   tags     → included if the class's tags contain all targeting tag key/value pairs
  #   compute  → included if class name matches (unusual for standalone, but supported)
  build_standalone_applications_by_class = {
    for class_name, class_config in local.build_classes : class_name => [
      for app_name, app_config in var.standalone_applications : app_config
      if contains(["ssm", "ansible"], try(app_config.type, "ssm")) && (
        # Wildcard: always include
        lookup(lookup(app_config, "targeting", {}), "mode", "wildcard") == "wildcard" ||
        # Tags: include if class tags match all targeting tags
        (
          lookup(lookup(app_config, "targeting", {}), "mode", "wildcard") == "tags" &&
          alltrue([
            for tag_key, tag_values in lookup(lookup(app_config, "targeting", {}), "tags", {}) :
            contains(tag_values, lookup(
              merge({ "Class" = class_name }, class_config.tags),
              tag_key, ""
            ))
          ])
        ) ||
        # Compute: include if class name matches
        (
          lookup(lookup(app_config, "targeting", {}), "mode", "wildcard") == "compute" &&
          class_name == app_name
        )
      )
    ]
  }

  # Filter to buildable applications per class (ssm, user-data, ansible  -  not helm)
  # Merges class-level applications with matched standalone applications
  build_applications = {
    for class_name, class_config in local.build_classes : class_name => concat(
      # Class-level applications (existing)
      [
        for app in try(class_config.applications, []) : app
        if contains(["ssm", "user-data", "ansible"], try(app.type, "ssm"))
      ],
      # Matched standalone applications
      local.build_standalone_applications_by_class[class_name]
    )
  }

  # Discover upload.yaml files for build-class ansible playbooks
  # These define source archives that need to be in S3 before the playbook runs
  build_upload_entries = flatten([
    for class_name, apps in local.build_applications : [
      for app in apps : [
        for idx, upload in try(yamldecode(
          file("${path.root}/applications/ansible/${app.playbook}/upload.yaml")
          ).uploads, []) : {
          class_name    = class_name
          playbook_name = app.playbook
          upload_idx    = idx
          source        = upload.source
          archive_name  = "${app.playbook}-upload-${idx}.tar.gz"
          s3_key        = "ansible-uploads/${app.playbook}/${app.playbook}-upload-${idx}.tar.gz"
        }
        if lookup(upload, "type", "git-archive") == "git-archive"
      ]
      if try(app.type, "") == "ansible"
      && fileexists("${path.root}/applications/ansible/${app.playbook}/upload.yaml")
    ]
  ])

  # Hash actual source file contents for each application in each build class
  # Ansible apps: hash all files in the playbook directory (playbook.yml, templates/, experiments/, etc.)
  # Script apps: hash the script file itself
  build_application_file_hashes = {
    for class_name, apps in local.build_applications : class_name => {
      for app in apps :
      coalesce(try(app.playbook, null), try(app.script, null), "unknown") => (
        try(app.type, "ssm") == "ansible"
        ? sha256(join("\n", [
          for f in sort(fileset("${path.root}/applications/ansible/${app.playbook}", "**")) :
          filesha256("${path.root}/applications/ansible/${app.playbook}/${f}")
        ]))
        : try(app.script, null) != null
        ? filesha256("${path.root}/applications/scripts/${app.script}")
        : "none"
      )
    }
  }

  # Content hash drives recipe/component naming
  # When base AMI, scripts, apps, or their source files change -> hash changes -> fresh build
  build_recipe_hash = {
    for class_name, class_config in local.build_classes :
    class_name => substr(sha256(jsonencode({
      parent_image = local.resolved_amis[class_name]
      volume_size  = class_config.volume_size
      applications = local.build_applications[class_name]
      file_hashes  = local.build_application_file_hashes[class_name]
    })), 0, 8)
  }
}

# ============================================================================
# Packer Template Generation
# ============================================================================

# Generate Packer HCL2 template for each build class
resource "local_file" "packer_template" {
  for_each = local.build_classes

  filename = "${path.module}/output/${each.key}-${local.build_recipe_hash[each.key]}.pkr.hcl"

  content = templatefile("${path.module}/templates/packer-build.pkr.hcl.tpl", {
    class_name       = each.key
    namespace        = var.namespace
    region           = data.aws_region.current.id
    base_ami         = local.resolved_amis[each.key]
    instance_type    = each.value.instance_type
    volume_size      = each.value.volume_size
    instance_profile = lookup(var.access_instance_profile_names, "build-packer", "")
    content_hash     = local.build_recipe_hash[each.key]
    ami_tags         = try(each.value.tags, {})
    terraform_root   = path.root
    # Use default network's VPC and public subnet for builds (allows internet access for SSM)
    vpc_id    = var.vpc_id
    subnet_id = var.subnet_id
    # Point to venv with Ansible + boto3
    ansible_venv_path = "${path.module}/output/ansible-venv/bin"
    # S3 bucket for playbook uploads (injected as ANSIBLE_PLAYBOOKS_BUCKET extra var)
    application_scripts_bucket = var.application_scripts_bucket

    # Detect Windows vs Linux from base AMI
    is_windows = length(regexall("(?i)windows", local.resolved_amis[each.key])) > 0

    # Generate appropriate inventory template based on OS
    inventory_template = length(regexall("(?i)windows", local.resolved_amis[each.key])) > 0 ? "[windows]\ndefault ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }} ansible_connection=winrm" : "[linux]\ndefault ansible_host={{ .Host }} ansible_user={{ .User }} ansible_port={{ .Port }}"

    # Split applications by type for provisioner generation
    script_apps = [
      for app in local.build_applications[each.key] : merge(app, {
        script_path = "${path.root}/applications/scripts/${app.script}"
      })
      if contains(["ssm", "user-data"], try(app.type, "ssm"))
    ]
    ansible_apps = [
      for app in local.build_applications[each.key] : merge(app, {
        playbook_path = "${path.root}/applications/ansible/${app.playbook}/${coalesce(try(app.playbook_file, null), "playbook.yml")}"
      })
      if try(app.type, "") == "ansible"
    ]
  })
}

# ============================================================================
# Ansible Environment Setup
# ============================================================================

# Create Python venv with boto3 for Ansible (runs on local machine)
resource "null_resource" "ansible_venv" {
  count = local.has_builds ? 1 : 0

  triggers = {
    # Recreate if requirements change
    requirements = sha256("ansible boto3 botocore")
  }

  provisioner "local-exec" {
    command = <<-EOT
      python3 -m venv ${path.module}/output/ansible-venv
      ${path.module}/output/ansible-venv/bin/pip install --upgrade pip
      ${path.module}/output/ansible-venv/bin/pip install ansible boto3 botocore
    EOT
  }
}

# ============================================================================
# Packer Build Execution
# ============================================================================

# Upload build-time archives to S3 before Packer runs
resource "null_resource" "build_upload_archives" {
  count = length(local.build_upload_entries)

  triggers = {
    source       = local.build_upload_entries[count.index].source
    archive_name = local.build_upload_entries[count.index].archive_name
    s3_key       = local.build_upload_entries[count.index].s3_key
    bucket       = var.application_scripts_bucket
    # Re-upload when source tree changes
    source_hash = sha256(jsonencode([
      for f in fileset("${path.root}/..", local.build_upload_entries[count.index].source) : f
    ]))
  }

  provisioner "local-exec" {
    command     = "aws s3 cp /dev/null s3://${self.triggers.bucket}/ 2>/dev/null || true && git archive --format=tar.gz --prefix=${basename(self.triggers.source)}/ -o /tmp/${self.triggers.archive_name} HEAD ${self.triggers.source} && aws s3 cp /tmp/${self.triggers.archive_name} s3://${self.triggers.bucket}/${self.triggers.s3_key}"
    working_dir = "${path.root}/.."
    environment = {
      AWS_PROFILE = var.aws_profile
      AWS_REGION  = data.aws_region.current.id
    }
  }
}

# Execute Packer builds via null_resource
resource "null_resource" "packer_build" {
  for_each = local.build_classes

  triggers = {
    template_hash = sha256(local_file.packer_template[each.key].content)
    class_name    = each.key
    content_hash  = local.build_recipe_hash[each.key]
    template_path = local_file.packer_template[each.key].filename
  }

  provisioner "local-exec" {
    command     = "packer init ${self.triggers.template_path} && packer build -force ${self.triggers.template_path}"
    working_dir = path.root
    environment = {
      AWS_PROFILE = var.aws_profile
      AWS_REGION  = data.aws_region.current.id
    }
  }

  depends_on = [
    local_file.packer_template,
    null_resource.ansible_venv,
    null_resource.build_upload_archives
  ]
}

# ============================================================================
# AMI Lookup from Packer Builds
# ============================================================================

# Lookup built AMIs via AWS data source (resilient to manifest file loss)
data "aws_ami" "packer_built" {
  for_each    = local.build_classes
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Class"
    values = [each.key]
  }

  filter {
    name   = "tag:ContentHash"
    values = [local.build_recipe_hash[each.key]]
  }

  filter {
    name   = "tag:BuiltBy"
    values = ["Packer"]
  }

  depends_on = [null_resource.packer_build]
}

# ============================================================================
# Preflight Checks
# ============================================================================

module "preflight" {
  source = "../preflight"

  required_tools = local.has_builds ? {
    packer = {
      type     = "discrete"
      commands = ["packer"]
    }
    python3 = {
      type     = "discrete"
      commands = ["python3"]
    }
  } : {}
}
