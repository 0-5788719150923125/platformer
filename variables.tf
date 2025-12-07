# Core Infrastructure Variables
variable "aws_profile" {
  description = "AWS profile name for authentication (e.g., 'example-platform-dev', 'example-account-prod')"
  type        = string
  default     = "example-platform-dev"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.aws_profile))
    error_message = "AWS profile name must contain only letters, numbers, hyphens, and underscores (no spaces)"
  }
}

variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-2"

  validation {
    condition     = can(regex("^[a-z]{2,3}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "AWS region must be a valid region format (e.g., 'us-east-1', 'eu-west-2', 'ap-southeast-1')"
  }
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
  default     = "Platform"
}

# Service Configuration
variable "states" {
  description = <<-EOT
    List of state fragments to load and merge from states/ directory.
    State fragments are YAML files that define service configurations.

    Loaded states are deep-merged in order (left-to-right).

    Examples:
      - ["configuration-management-hourly"]
      - ["configuration-management", "compute-windows-test"]
      - []  # No states (no services will be created)

    State fragments may contain a 'matrix' key for CI/CD regions and tenant
    targeting dimensions (matrix.tenants). Terraform deploys to ONE region
    at a time (specified by var.aws_region).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.states : can(regex("^[a-z0-9-]+$", s))])
    error_message = "State names must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "workspace_overrides" {
  description = "Whether to enable workspace-specific tfvars file overrides. Set to false in tests to ensure test variables are used directly."
  type        = bool
  default     = true
}

variable "aws_sso_start_url" {
  description = "AWS SSO start URL for console link wrapping (e.g., https://d-xxxxxxxxxx.awsapps.com/start)"
  type        = string
  default     = "https://d-1234567890.awsapps.com/start"
}
