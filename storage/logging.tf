# S3 access logging configuration
resource "aws_s3_bucket_logging" "requested" {
  for_each = {
    for k, v in local.buckets : k => v
    if v.access_logging && local.needs_log_bucket
  }

  bucket = aws_s3_bucket.requested[each.key].id

  target_bucket = aws_s3_bucket.access_logs[0].id
  target_prefix = "${each.value.purpose}/"
}

# Grant S3 log delivery permissions to access logs bucket
resource "aws_s3_bucket_policy" "access_logs" {
  count = local.needs_log_bucket ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ServerAccessLogsPolicy"
        Effect = "Allow"
        Principal = {
          Service = "logging.s3.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs[0].arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}
