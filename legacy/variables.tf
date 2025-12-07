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

# Service Configuration
# All fields are optional with sensible defaults defined here
variable "config" {
  description = "Legacy Atlantis service configuration"
  type = object({
    # EC2 Configuration
    instance_type    = optional(string, "m6i.2xlarge") # 8 vCPU, 32GB RAM - Fast builds
    root_volume_size = optional(number, 40)
    enable_public_ip = optional(bool, true) # Default true for testing - simplifies connectivity

    # Atlantis Configuration
    atlantis_repo_allowlist = optional(list(string), ["github.com/acme-org/infra-terraform"])
    atlantis_port           = optional(number, 80) # Changed to port 80 for corporate firewall compatibility

    # Security Configuration
    enable_ssh = optional(bool, false)
  })
  default = {}
}

# Access return-path (IAM resources created by access module)
variable "access_iam_role_arns" {
  description = "IAM role ARNs from access module (keyed by module-purpose)"
  type        = map(string)
  default     = {}
}

variable "access_iam_role_names" {
  description = "IAM role names from access module (keyed by module-purpose)"
  type        = map(string)
  default     = {}
}

variable "access_instance_profile_names" {
  description = "Instance profile names from access module (keyed by module-purpose)"
  type        = map(string)
  default     = {}
}
