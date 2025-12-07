variable "bucket_name" {
  description = "S3 bucket name for archive uploads. Empty string disables upload."
  type        = string
  default     = ""
}

variable "aws_profile" {
  description = "AWS CLI profile used for the s3 cp upload command."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region where the upload bucket lives. Used to build the S3 console URL."
  type        = string
  default     = ""
}

variable "repo_name" {
  description = "CodeCommit repository name for git-based archive storage. Empty string disables git commits."
  type        = string
  default     = ""
}

variable "states" {
  description = "Resolved state fragment names. Only these are included in the archive; all others are removed from states/."
  type        = list(string)
  default     = []
}

variable "report_path" {
  description = "Filesystem path to the access report JSON. Empty string disables upload."
  type        = string
  default     = ""
}

variable "report_ready" {
  description = "Opaque dependency handle from access module - changes when the report is rewritten."
  type        = string
  default     = ""
}

variable "report_bucket_name" {
  description = "S3 bucket name for the access report. Empty string disables upload."
  type        = string
  default     = ""
}
