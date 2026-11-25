# Lifecycle rules for S3 buckets
resource "aws_s3_bucket_lifecycle_configuration" "requested" {
  for_each = {
    for k, v in local.buckets : k => v
    if v.lifecycle_days != null || v.glacier_days != null || v.intelligent_tiering
  }

  bucket = aws_s3_bucket.requested[each.key].id

  rule {
    id     = "lifecycle-management"
    status = "Enabled"

    # Apply to all objects
    filter {}

    # Intelligent-Tiering optimization
    dynamic "transition" {
      for_each = each.value.intelligent_tiering ? [1] : []
      content {
        days          = 0
        storage_class = "INTELLIGENT_TIERING"
      }
    }

    # Standard-IA transition
    dynamic "transition" {
      for_each = each.value.lifecycle_days != null && !each.value.intelligent_tiering ? [1] : []
      content {
        days          = each.value.lifecycle_days
        storage_class = "STANDARD_IA"
      }
    }

    # Glacier transition
    dynamic "transition" {
      for_each = each.value.glacier_days != null ? [1] : []
      content {
        days          = each.value.glacier_days
        storage_class = "GLACIER"
      }
    }
  }
}
