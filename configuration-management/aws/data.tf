# Data source to get current AWS region
data "aws_region" "current" {}

# Data source to get current AWS account information
data "aws_caller_identity" "current" {}
