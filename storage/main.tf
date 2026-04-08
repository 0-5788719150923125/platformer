# Local variables for bucket expansion
locals {
  # Create map of buckets from bucket_requests
  # Key format: "{purpose}" (purpose must be unique per validation)
  buckets = {
    for idx, req in var.bucket_requests :
    req.purpose => {
      # Bucket naming: optional prefix + purpose + namespace
      # Example: "ssm-logs-ssm-association-logs-glad-fawn"
      # Or if no prefix: "ssm-association-logs-glad-fawn"
      bucket_name = req.prefix != "" ? "${req.prefix}-${req.purpose}-${var.namespace}" : "${req.purpose}-${var.namespace}"

      purpose             = req.purpose
      description         = req.description
      versioning_enabled  = req.versioning_enabled
      lifecycle_days      = req.lifecycle_days
      glacier_days        = req.glacier_days
      intelligent_tiering = req.intelligent_tiering
      access_logging      = req.access_logging
      cors_enabled        = req.cors_enabled
      public_access       = req.public_access
      force_destroy       = req.force_destroy
      on_create_command   = req.on_create_command
      upload_trigger      = req.upload_trigger
    }
  }

  # Separate log destination bucket (if any bucket requests access_logging)
  needs_log_bucket = anytrue([for bucket in local.buckets : bucket.access_logging])
  log_bucket_name  = "access-logs-${var.namespace}"
}

# Replacement sentinels - replaced whenever the corresponding bucket is replaced.
# Exposes a stable ID that changes on bucket recreation, allowing downstream
# modules to trigger re-uploads without relying on the bucket name (which is
# stable across replacements).
resource "terraform_data" "bucket_replaced" {
  for_each = aws_s3_bucket.requested
  input    = each.value.id

  lifecycle {
    replace_triggered_by = [aws_s3_bucket.requested[each.key]]
  }
}

# S3 buckets (dependency inversion pattern)
# Other modules define bucket requirements via bucket_requests variable
resource "aws_s3_bucket" "requested" {
  for_each = local.buckets

  bucket        = each.value.bucket_name
  force_destroy = each.value.force_destroy

  lifecycle {
    # S3 bucket names are globally unique - two buckets with the same name cannot
    # coexist. Explicit false overrides any create_before_destroy = true propagation
    # from upstream resources, ensuring the old bucket is always destroyed first.
    create_before_destroy = false
  }

  tags = {
    Name        = each.value.bucket_name
    Purpose     = each.value.purpose
    Description = each.value.description
    Namespace   = var.namespace
  }
}

# Post-creation upload (optional, per bucket request)
# Runs on_create_command immediately after the bucket exists.
# upload_trigger carries an opaque dependency value from the requester (e.g., a
# null_resource.id) so this re-runs whenever the source artifact changes.
resource "null_resource" "post_create_upload" {
  for_each = {
    for k, v in local.buckets : k => v
    if v.on_create_command != null
  }

  triggers = {
    bucket_id      = aws_s3_bucket.requested[each.key].id
    upload_trigger = each.value.upload_trigger
  }

  provisioner "local-exec" {
    command = each.value.on_create_command
  }
}

# Bucket versioning
resource "aws_s3_bucket_versioning" "requested" {
  for_each = {
    for k, v in local.buckets : k => v
    if v.versioning_enabled
  }

  bucket = aws_s3_bucket.requested[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Block public access (default: enabled, can override per bucket)
resource "aws_s3_bucket_public_access_block" "requested" {
  for_each = local.buckets

  bucket = aws_s3_bucket.requested[each.key].id

  block_public_acls       = !each.value.public_access
  block_public_policy     = !each.value.public_access
  ignore_public_acls      = !each.value.public_access
  restrict_public_buckets = !each.value.public_access
}

# Server-side encryption (always enabled with SSE-S3)
resource "aws_s3_bucket_server_side_encryption_configuration" "requested" {
  for_each = local.buckets

  bucket = aws_s3_bucket.requested[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3 (default AWS encryption)
    }
    bucket_key_enabled = true # Reduce KMS costs if using KMS
  }
}

# Access logging destination bucket (separate, centralized)
resource "aws_s3_bucket" "access_logs" {
  count = local.needs_log_bucket ? 1 : 0

  bucket        = local.log_bucket_name
  force_destroy = true

  tags = {
    Name      = local.log_bucket_name
    Purpose   = "s3-access-logs"
    Namespace = var.namespace
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = local.needs_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policies for EC2 instance access (DHMC role)
# Allow EC2 instances using Default Host Management Configuration to access hooks bucket
resource "aws_s3_bucket_policy" "hooks_access" {
  for_each = {
    for k, v in local.buckets : k => v
    if v.purpose == "hooks"
  }

  bucket = aws_s3_bucket.requested[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountEC2Instances"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:ListBucket",
          "s3:GetObject"
        ]
        Resource = [
          aws_s3_bucket.requested[each.key].arn,
          "${aws_s3_bucket.requested[each.key].arn}/*"
        ]
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}
