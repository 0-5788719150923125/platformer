variable "default_aws_profile" {
  description = "Default AWS profile from base terraform.tfvars (null = AWS not configured)"
  type        = string
  default     = null
}

variable "default_aws_region" {
  description = "Default AWS region from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
  type        = string
}

variable "default_states" {
  description = "Default state fragments list from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
  type        = list(string)
}

variable "default_states_paths" {
  description = "Default extra state fragment search paths from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
  type        = list(string)
  default     = []
}

variable "default_owner" {
  description = "Default owner from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
  type        = string
}

variable "workspace_file_path" {
  description = "Override the workspace file to parse (default: terraform.tfvars.<workspace> in the root). Used by tests to point at fixtures."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to resolve workspace-specific overrides from tfvars files. When false, always returns defaults (useful for tests)."
  type        = bool
  default     = true
}
