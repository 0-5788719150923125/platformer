# Generic SSM Associations
# Supports associations to AWS-managed or external SSM documents
# Use this for documents NOT in the documents/ directory (e.g., AWS-GatherSoftwareInventory)
#
# This is the generic interface for ANY SSM association, following the same pattern
# as the documents/ directory but supporting external document references.

locals {
  # Filter application requests by type
  # Configuration-management handles SSM and Ansible deployment types
  ssm_application_requests = [
    for req in var.application_requests : req
    if req.type == "ssm"
  ]

  ansible_application_requests = [
    for req in var.application_requests : req
    if req.type == "ansible"
  ]

  # Detect if any application targets instances outside compute (wildcard or tag-based)
  # Used to broaden S3 bucket policy so non-compute instances can download playbooks/scripts
  has_non_compute_targets = anytrue([
    for req in var.application_requests :
    coalesce(req.targeting_mode, "compute") != "compute"
  ])

  # Filter to enabled associations only
  generic_enabled_associations = {
    for name, config in var.config.associations : name => config
    if config.enabled
  }

  # Build association configs with defaults from global settings
  generic_association_configs = {
    for name, config in local.generic_enabled_associations : name => {
      document_name       = config.document_name
      schedule_expression = coalesce(config.schedule_expression, var.config.schedule_expression)
      # Rate control parameters: only set if explicitly provided (Policy documents don't support them)
      max_concurrency     = config.max_concurrency
      max_errors          = config.max_errors
      compliance_severity = coalesce(config.compliance_severity, var.config.compliance_severity)
      parameters          = config.parameters
      targets             = config.targets
    }
  }
}

# SSM State Manager Associations for external/AWS-managed documents
resource "aws_ssm_association" "generic" {
  for_each = local.generic_association_configs

  name             = each.value.document_name
  association_name = "${each.key}-${var.namespace}"

  # Schedule configuration
  schedule_expression = each.value.schedule_expression

  # Parameters (if any)
  parameters = each.value.parameters

  # Targets configuration
  dynamic "targets" {
    for_each = each.value.targets
    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  # Compliance and control settings
  compliance_severity = each.value.compliance_severity

  # Rate control parameters: Only set for Command/Automation documents (Policy documents don't support them)
  max_concurrency = each.value.max_concurrency
  max_errors      = each.value.max_errors
}

# Application Associations
# Consumes application requests from applications module (dependency inversion)
# Creates SSM associations for application installation
#
# Why here instead of applications module?
# - Centralized SSM orchestration (all SSM associations in one place)
# - Consistent rate controls and compliance settings
# - Unified logging and monitoring
# - Separation of concerns: applications defines WHAT, configuration-management defines HOW
# - Applications module is deployment-agnostic (no SSM knowledge)

# Upload application scripts to S3
# Configuration-management owns the deployment mechanism (S3 + SSM)
resource "aws_s3_object" "application_scripts" {
  count = length(local.ssm_application_requests)

  bucket = var.application_scripts_bucket
  key    = "applications/${local.ssm_application_requests[count.index].script}"
  source = local.ssm_application_requests[count.index].script_source_path
  etag   = filemd5(local.ssm_application_requests[count.index].script_source_path)

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# SSM State Manager Associations for application installation
# Using count instead of for_each to avoid dynamic map key issues with namespace
# Builds SSM-specific structures from deployment-agnostic application requests
resource "aws_ssm_association" "applications" {
  count = length(local.ssm_application_requests)

  name                = "AWS-RunShellScript"
  association_name    = "app-${local.ssm_application_requests[count.index].class}-${replace(local.ssm_application_requests[count.index].script, "/", "-")}-${var.namespace}"
  schedule_expression = "rate(30 minutes)"

  # Build commands parameter dynamically with scripts bucket
  parameters = {
    commands = <<-EOT
      set -e
      echo 'Downloading application script from S3...'
      aws s3 cp s3://${var.application_scripts_bucket}/applications/${local.ssm_application_requests[count.index].script} /tmp/${local.ssm_application_requests[count.index].script}
      chmod +x /tmp/${local.ssm_application_requests[count.index].script}
      echo 'Executing application script...'
      ${join("\n", [for k, v in local.ssm_application_requests[count.index].params : "export ${k}='${v}'"])}
      /tmp/${local.ssm_application_requests[count.index].script}
    EOT
  }

  # Targets configuration - use tag-based targeting from application request
  # Multiple targets blocks = AND logic: Class AND Tenant must both match
  targets {
    key    = "tag:${local.ssm_application_requests[count.index].target_tag_key}"
    values = [local.ssm_application_requests[count.index].target_tag_value]
  }

  targets {
    key    = "tag:Tenant"
    values = [local.ssm_application_requests[count.index].tenant]
  }

  # Output location (dynamically built)
  dynamic "output_location" {
    for_each = var.application_scripts_bucket != "" ? [1] : []
    content {
      s3_bucket_name = var.application_scripts_bucket
      s3_key_prefix  = "ssm-logs/applications/"
    }
  }

  # Compliance settings - configuration-management decides this, not applications
  compliance_severity = "MEDIUM"
}

# IAM policies for SSM-based application deployment
# These are deployment-method-specific (only needed for SSM associations)

# IAM policies for SSM-based application deployment
# These are deployment-method-specific (only needed for SSM associations)

# IAM Role Policy for Application Scripts
# Grants S3 access to instance role for downloading scripts and Ansible playbooks
# Falls back to existing_instance_role_name for standalone deployments without compute
resource "aws_iam_role_policy" "application_scripts_access" {
  count = length(local.ssm_application_requests) > 0 || length(local.ansible_application_requests) > 0 ? 1 : 0

  name = "application-scripts-s3-access"
  role = coalesce(var.instances_role_name, var.config.existing_instance_role_name)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.application_scripts_bucket}",
          "arn:aws:s3:::${var.application_scripts_bucket}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.application_scripts_bucket}/ssm-logs/*"
        ]
      }
    ]
  })
}

# S3 Bucket Policy for Application Scripts
# Allows compute instance role, CodeBuild controller, and SSM service to access scripts bucket
# When wildcard/tag-targeted applications exist, grants read access to any role in the account
# so non-compute instances can download playbooks and scripts
resource "aws_s3_bucket_policy" "application_scripts_access" {
  count = length(local.ssm_application_requests) > 0 || length(local.ansible_application_requests) > 0 ? 1 : 0

  bucket = var.application_scripts_bucket

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # Statement 1: Allow compute instance role to access scripts (when role exists)
      var.instances_role_arn != "" ? [
        {
          Sid    = "AllowInstanceRoleAccess"
          Effect = "Allow"
          Principal = {
            AWS = var.instances_role_arn
          }
          Action = [
            "s3:ListBucket",
            "s3:GetObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.application_scripts_bucket}",
            "arn:aws:s3:::${var.application_scripts_bucket}/*"
          ]
        }
      ] : [],
      # Statement 2: Allow any principal in the account to read scripts (for wildcard/tag-targeted apps)
      # Uses Principal: * with account condition so access is granted directly by the bucket policy,
      # not delegated to IAM (which would fail for roles lacking S3 permissions)
      local.has_non_compute_targets ? [
        {
          Sid    = "AllowAccountWideRead"
          Effect = "Allow"
          Principal = {
            AWS = "*"
          }
          Action = [
            "s3:ListBucket",
            "s3:GetObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.application_scripts_bucket}",
            "arn:aws:s3:::${var.application_scripts_bucket}/*"
          ]
          Condition = {
            StringEquals = {
              "aws:PrincipalAccount" = var.aws_account_id
            }
          }
        }
      ] : [],
      # Statement 3: Allow CodeBuild controller to read/write bucket (for playbook download and aws_ssm file transfer)
      local.ansible_controller_enabled ? [
        {
          Sid    = "AllowCodeBuildControllerAccess"
          Effect = "Allow"
          Principal = {
            AWS = var.access_iam_role_arns["configuration-management-ansible-controller"]
          }
          Action = [
            "s3:ListBucket",
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:GetBucketLocation"
          ]
          Resource = [
            "arn:aws:s3:::${var.application_scripts_bucket}",
            "arn:aws:s3:::${var.application_scripts_bucket}/*"
          ]
        }
      ] : [],
      # Statement 4: SSM service can write logs (script associations)
      [
        {
          Sid    = "AllowSSMServiceToWriteLogs"
          Effect = "Allow"
          Principal = {
            Service = "ssm.amazonaws.com"
          }
          Action = [
            "s3:PutObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.application_scripts_bucket}/ssm-logs/applications/*"
          ]
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = var.aws_account_id
            }
          }
        }
      ]
    )
  })
}

# ========================================
# Ansible Playbook S3 Upload Pipeline
# Uploads playbooks and their dependencies to S3 for the CodeBuild controller
# ========================================

locals {
  # Detect playbook dependencies by scanning for import_playbook directives
  # Level 1: Scan requested playbooks for imports
  ansible_playbook_dependencies_level1 = flatten([
    for req in local.ansible_application_requests : concat(
      # Start with the requested playbook itself (resolve relative to root)
      [{
        playbook_name        = req.playbook
        playbook_source_path = "${path.root}/${req.playbook_source_path}"
      }],
      # Scan for import_playbook directives
      # Use path.root to resolve relative paths from applications module correctly
      [
        for import_match in regexall("import_playbook:\\s*([^\\s#]+)",
          fileexists("${path.root}/${req.playbook_source_path}/${coalesce(req.playbook_file, "playbook.yml")}")
          ? file("${path.root}/${req.playbook_source_path}/${coalesce(req.playbook_file, "playbook.yml")}")
          : ""
          ) : {
          # Extract playbook name from import path
          # "../docker/playbook.yml" → "docker"
          playbook_name = basename(dirname(trimspace(import_match[0])))
          # Resolve source path: try module-specific location first, fall back to shared
          # The import path "../docker/playbook.yml" refers to the S3 structure, not filesystem
          # So we need to find "docker" playbook in either:
          # 1. {module}/ansible/docker (module-specific)
          # 2. applications/ansible/docker (shared)
          playbook_source_path = fileexists("${path.root}/${split("-", req.class)[0]}/ansible/${basename(dirname(trimspace(import_match[0])))}/playbook.yml") ? "${path.root}/${split("-", req.class)[0]}/ansible/${basename(dirname(trimspace(import_match[0])))}" : "${path.root}/applications/ansible/${basename(dirname(trimspace(import_match[0])))}"
        }
      ]
    )
  ])

  # Level 2: Scan level 1 imports for their own imports (recursive dependency detection)
  ansible_playbook_dependencies_level2 = flatten([
    for dep in local.ansible_playbook_dependencies_level1 : [
      for import_match in regexall("import_playbook:\\s*([^\\s#]+)",
        fileexists("${dep.playbook_source_path}/playbook.yml")
        ? file("${dep.playbook_source_path}/playbook.yml")
        : ""
        ) : {
        playbook_name        = basename(dirname(trimspace(import_match[0])))
        playbook_source_path = fileexists("${path.root}/applications/ansible/${basename(dirname(trimspace(import_match[0])))}/playbook.yml") ? "${path.root}/applications/ansible/${basename(dirname(trimspace(import_match[0])))}" : "${path.root}/applications/ansible/${basename(dirname(trimspace(import_match[0])))}"
      }
    ]
  ])

  # Combine all levels and deduplicate
  ansible_playbook_dependencies = distinct(concat(
    local.ansible_playbook_dependencies_level1,
    local.ansible_playbook_dependencies_level2
  ))

  # Deduplicate by playbook_name (multiple playbooks may import the same dependency)
  unique_ansible_playbooks = {
    for playbook_name, paths in {
      for dep in local.ansible_playbook_dependencies :
      dep.playbook_name => dep.playbook_source_path...
    } :
    playbook_name => paths[0]
  }

  # Upload ALL playbooks to S3 (requested + dependencies)
  # Scans each playbook directory for all files (playbook.yml, compose.yml, templates, etc.)
  ansible_playbook_files = flatten([
    for playbook_name, playbook_source_path in local.unique_ansible_playbooks : [
      for file in fileset(playbook_source_path, "**") : {
        playbook_name = playbook_name
        source_path   = "${playbook_source_path}/${file}"
        s3_key        = "ansible-playbooks/${playbook_name}/${file}"
      }
    ]
  ])

  # Discover IAM policy files alongside Ansible playbooks
  # Follows the same pattern as documents/ directory: playbook.iam.json
  ansible_playbook_iam_policies = {
    for playbook_name, playbook_source_path in local.unique_ansible_playbooks :
    playbook_name => {
      has_iam_policy  = fileexists("${playbook_source_path}/playbook.iam.json")
      iam_policy_file = "${playbook_source_path}/playbook.iam.json"
    }
  }

  # Filter to only playbooks that have IAM policy files
  ansible_playbooks_with_iam_policies = {
    for playbook_name, config in local.ansible_playbook_iam_policies :
    playbook_name => config
    if config.has_iam_policy
  }

  # Read IAM policy files (no template rendering needed for ansible playbooks)
  ansible_playbook_iam_policies_rendered = {
    for playbook_name, config in local.ansible_playbooks_with_iam_policies :
    playbook_name => file(config.iam_policy_file)
  }

  # Discover upload.yaml files alongside Ansible playbooks
  # These define additional files/directories to upload via git archive
  ansible_playbook_uploads = {
    for playbook_name, playbook_source_path in local.unique_ansible_playbooks :
    playbook_name => {
      has_upload_config  = fileexists("${playbook_source_path}/upload.yaml")
      upload_config_file = "${playbook_source_path}/upload.yaml"
    }
  }

  # Parse upload configs for playbooks that have them
  ansible_playbook_upload_configs = {
    for playbook_name, config in local.ansible_playbook_uploads :
    playbook_name => yamldecode(file(config.upload_config_file))
    if config.has_upload_config
  }

  # Flatten uploads into a list with playbook context (git-archive type, default)
  ansible_playbook_upload_entries = flatten([
    for playbook_name, config in local.ansible_playbook_upload_configs : [
      for idx, upload in config.uploads : {
        playbook_name = playbook_name
        upload_idx    = idx
        source        = upload.source
        prefix        = lookup(upload, "prefix", basename(upload.source))
        dest          = upload.dest
        archive_name  = "${playbook_name}-upload-${idx}.tar.gz"
        s3_key        = "ansible-uploads/${playbook_name}/${playbook_name}-upload-${idx}.tar.gz"
      }
      if lookup(upload, "type", "git-archive") == "git-archive"
    ]
  ])

  # URL-type uploads: download a file from a URL and push to S3
  # Used when instances lack outbound internet access to the source
  ansible_playbook_url_upload_entries = flatten([
    for playbook_name, config in local.ansible_playbook_upload_configs : [
      for idx, upload in config.uploads : {
        playbook_name = playbook_name
        upload_idx    = idx
        url           = upload.url
        filename      = upload.filename
        s3_key        = "ansible-uploads/${playbook_name}/${upload.filename}"
      }
      if lookup(upload, "type", "git-archive") == "url"
    ]
  ])
}

# Get git tree hash for each upload source (used as trigger for re-archiving)
data "external" "upload_source_hash" {
  count   = length(local.ansible_playbook_upload_entries)
  program = ["bash", "-c", "SRC='${local.ansible_playbook_upload_entries[count.index].source}'; if [ \"$SRC\" = '.' ]; then HASH=$(git rev-parse HEAD); else HASH=$(git rev-parse HEAD:$SRC); fi; echo \"{\\\"hash\\\":\\\"$HASH\\\"}\""]

  working_dir = path.root
}

# Create git archives for ansible playbook uploads
# Uses git archive to respect .gitignore
resource "null_resource" "ansible_upload_archives" {
  count = length(local.ansible_playbook_upload_entries)

  triggers = {
    # Re-run when git tree hash changes (consistent with git archive behavior)
    source_hash  = data.external.upload_source_hash[count.index].result.hash
    archive_name = local.ansible_playbook_upload_entries[count.index].archive_name
  }

  provisioner "local-exec" {
    command     = "mkdir -p ${path.module}/uploads && git archive --format=tar.gz --prefix=${local.ansible_playbook_upload_entries[count.index].prefix}/ -o ${path.module}/uploads/${local.ansible_playbook_upload_entries[count.index].archive_name} HEAD ${local.ansible_playbook_upload_entries[count.index].source}"
    working_dir = path.root
  }
}

# Ensure uploads directory exists
resource "null_resource" "ansible_uploads_dir" {
  count = length(local.ansible_playbook_upload_entries) + length(local.ansible_playbook_url_upload_entries) > 0 ? 1 : 0

  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/uploads"
  }
}

# Upload git archives to S3
resource "aws_s3_object" "ansible_upload_archives" {
  count = length(local.ansible_playbook_upload_entries)

  bucket = var.application_scripts_bucket
  key    = local.ansible_playbook_upload_entries[count.index].s3_key
  source = "${path.module}/uploads/${local.ansible_playbook_upload_entries[count.index].archive_name}"

  depends_on = [null_resource.ansible_upload_archives, null_resource.ansible_uploads_dir]

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# Download files from URLs for url-type uploads
# These are fetched at plan/apply time (where internet access exists)
# and pushed to S3 so instances can retrieve them without outbound internet
resource "null_resource" "ansible_url_upload_downloads" {
  count = length(local.ansible_playbook_url_upload_entries)

  triggers = {
    url      = local.ansible_playbook_url_upload_entries[count.index].url
    filename = local.ansible_playbook_url_upload_entries[count.index].filename
  }

  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/uploads && curl -fsSL -o ${path.module}/uploads/${local.ansible_playbook_url_upload_entries[count.index].filename} '${local.ansible_playbook_url_upload_entries[count.index].url}'"
  }
}

# Upload URL-downloaded files to S3
resource "aws_s3_object" "ansible_url_upload_files" {
  count = length(local.ansible_playbook_url_upload_entries)

  bucket = var.application_scripts_bucket
  key    = local.ansible_playbook_url_upload_entries[count.index].s3_key
  source = "${path.module}/uploads/${local.ansible_playbook_url_upload_entries[count.index].filename}"

  depends_on = [null_resource.ansible_url_upload_downloads, null_resource.ansible_uploads_dir]

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# Upload all files from Ansible playbook directories to S3
# Automatically includes playbook.yml, compose.yml, templates, scripts, etc.
# Convention: entire directory contents are uploaded, no explicit file list needed
resource "aws_s3_object" "ansible_playbook_files" {
  count = length(local.ansible_playbook_files)

  bucket = var.application_scripts_bucket
  key    = local.ansible_playbook_files[count.index].s3_key
  source = local.ansible_playbook_files[count.index].source_path
  etag   = filemd5(local.ansible_playbook_files[count.index].source_path)

  tags = {
    Namespace = var.namespace
    Module    = "configuration-management"
  }
}

# Ansible Playbooks: Deployed via CodeBuild controller (ansible-controller.tf)
# No SSM document or associations needed  -  controller runs playbooks remotely via aws_ssm connection

# ========================================
# Application IAM Permissions
# ========================================
# Auto-attach IAM policies defined in playbook.iam.json alongside Ansible playbooks.
# Follows the same pattern as documents/ directory (e.g., windows-password-rotation.iam.json).
# This provides a generic interface for applications to declare their required IAM
# permissions without needing dedicated modules.

# Attach IAM policies to instance role (compute role when available, else default SSM role)
resource "aws_iam_role_policy" "ansible_application_permissions" {
  for_each = length(local.ansible_application_requests) > 0 ? local.ansible_playbooks_with_iam_policies : {}

  name   = "ansible-${each.key}-${var.namespace}"
  role   = coalesce(var.instances_role_name, var.config.existing_instance_role_name)
  policy = local.ansible_playbook_iam_policies_rendered[each.key]
}
