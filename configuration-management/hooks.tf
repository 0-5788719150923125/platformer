# Universal Hook System
# Provides intelligent pre/post lifecycle hooks for managed instances
# Hooks detect services (Redis, PostgreSQL, etc.) and perform appropriate actions
# No tags or configuration required - hooks are applied universally
#
# Bucket is created by storage module via bucket_requests (dependency inversion pattern)

locals {
  # Enable hooks if patch management is enabled
  hooks_enabled = local.patch_enabled
}

# Upload Linux pre-install hook scripts
resource "aws_s3_object" "linux_pre_scripts" {
  for_each = local.hooks_enabled ? fileset("${path.module}/hooks/linux/pre/", "*.sh") : []

  bucket = var.hooks_bucket
  key    = "hooks/linux/pre/${each.value}"
  source = "${path.module}/hooks/linux/pre/${each.value}"
  etag   = filemd5("${path.module}/hooks/linux/pre/${each.value}")

  tags = {
    Name      = each.value
    Namespace = var.namespace
    HookType  = "pre"
    OS        = "linux"
  }
}

# Upload Linux post-install hook scripts
resource "aws_s3_object" "linux_post_scripts" {
  for_each = local.hooks_enabled ? fileset("${path.module}/hooks/linux/post/", "*.sh") : []

  bucket = var.hooks_bucket
  key    = "hooks/linux/post/${each.value}"
  source = "${path.module}/hooks/linux/post/${each.value}"
  etag   = filemd5("${path.module}/hooks/linux/post/${each.value}")

  tags = {
    Name      = each.value
    Namespace = var.namespace
    HookType  = "post"
    OS        = "linux"
  }
}

# SSM Document: Linux Pre-Install Hook Orchestrator
resource "aws_ssm_document" "universal_preinstall_linux" {
  count = local.hooks_enabled ? 1 : 0

  name            = "ORG-Universal-PreInstall-Linux-${var.namespace}"
  document_type   = "Command"
  document_format = "YAML"
  content = templatefile("${path.module}/hooks/preinstall-orchestrator.yaml", {
    default_bucket = var.hooks_bucket
  })

  tags = {
    Name      = "ORG-Universal-PreInstall-Linux-${var.namespace}"
    Namespace = var.namespace
    Purpose   = "Universal pre-install hooks for Linux"
  }
}

# SSM Document: Linux Post-Install Hook Orchestrator
resource "aws_ssm_document" "universal_postinstall_linux" {
  count = local.hooks_enabled ? 1 : 0

  name            = "ORG-Universal-PostInstall-Linux-${var.namespace}"
  document_type   = "Command"
  document_format = "YAML"
  content = templatefile("${path.module}/hooks/postinstall-orchestrator.yaml", {
    default_bucket = var.hooks_bucket
  })

  tags = {
    Name      = "ORG-Universal-PostInstall-Linux-${var.namespace}"
    Namespace = var.namespace
    Purpose   = "Universal post-install hooks for Linux"
  }
}
