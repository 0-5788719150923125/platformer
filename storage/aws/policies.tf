# Bucket policies (e.g., CORS, CloudFront OAI)
resource "aws_s3_bucket_cors_configuration" "requested" {
  for_each = {
    for k, v in local.buckets : k => v
    if v.cors_enabled
  }

  bucket = aws_s3_bucket.requested[each.key].id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"] # Override via module config for specific origins
    max_age_seconds = 3000
  }
}

locals {
  access_resource_policies = concat(
    # Access logs bucket policy
    local.needs_log_bucket ? [
      {
        module        = "storage"
        resource_type = "s3-bucket-policy"
        resource_name = aws_s3_bucket.access_logs[0].bucket
        policy        = aws_s3_bucket_policy.access_logs[0].policy
      }
    ] : [],
    # Hooks bucket policy
    [
      for k, bp in aws_s3_bucket_policy.hooks_access : {
        module        = "storage"
        resource_type = "s3-bucket-policy"
        resource_name = aws_s3_bucket.requested[k].bucket
        policy        = bp.policy
      }
    ],
  )
}
