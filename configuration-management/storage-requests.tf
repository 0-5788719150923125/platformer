# Storage Requests - Define S3 buckets needed by this module
# Storage module creates buckets from these definitions (dependency inversion pattern)

locals {
  # SSM association logs bucket (when s3_output_bucket_enabled)
  ssm_logs_bucket_request = var.config.s3_output_bucket_enabled ? [
    {
      purpose             = "ssm-association-logs"
      description         = "SSM Association execution logs for configuration management"
      versioning_enabled  = true
      lifecycle_days      = 90
      intelligent_tiering = true
      access_logging      = true
      prefix              = "ssm-logs"
      cors_enabled        = false
      public_access       = false
      force_destroy       = true
    }
  ] : []

  # Hooks bucket (when patch management enabled)
  hooks_bucket_request = local.patch_enabled ? [
    {
      purpose             = "hooks"
      description         = "Universal hook scripts for pre/post install lifecycle events"
      versioning_enabled  = true
      lifecycle_days      = 90
      intelligent_tiering = false
      access_logging      = true
      prefix              = "org-platform"
      cors_enabled        = false
      public_access       = false
      force_destroy       = true
    }
  ] : []

  # Application scripts bucket (when application deployments exist)
  # Configuration-management owns the deployment mechanism, so it requests the S3 bucket
  # SSM applications use the bucket for script downloads; Ansible controller uses it for playbooks and manifests
  # Condition uses var.has_application_deployments (computed from config) rather than
  # local.ssm_application_requests (computed from var.application_requests) to avoid a
  # dependency cycle: build ← storage ← config-mgmt.bucket_requests ← compute ← build
  application_scripts_bucket_request = var.has_application_deployments ? [
    {
      purpose             = "application-scripts"
      description         = "Application scripts and Ansible playbooks for deployment"
      versioning_enabled  = true
      lifecycle_days      = 90
      intelligent_tiering = false
      access_logging      = true
      prefix              = "applications"
      cors_enabled        = false
      public_access       = false
      force_destroy       = true
    }
  ] : []

  # Combined bucket requests (all buckets this module needs)
  bucket_requests = concat(
    local.ssm_logs_bucket_request,
    local.hooks_bucket_request,
    local.application_scripts_bucket_request
  )
}
