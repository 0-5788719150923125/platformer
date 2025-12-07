# Core Variables (passed from root)
variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for IAM policy resources"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number"
  }
}

variable "aws_region" {
  description = "AWS region for constructing ARNs"
  type        = string
}

# Service-specific configuration from services.observability
variable "config" {
  description = "Observability stack configuration (components, agent, compute)"
  type        = any
  default     = {}
}

