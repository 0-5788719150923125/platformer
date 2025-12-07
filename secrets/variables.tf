variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for resource policies"
  type        = string
}

variable "config" {
  description = "Secret replication configuration from state fragments (services.secrets)"
  type        = any
  default     = {}
}
