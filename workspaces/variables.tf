variable "default_aws_profile" {
  description = "Default AWS profile from base terraform.tfvars (null = AWS not configured)"
  type        = string
  default     = null
}

variable "default_aws_region" {
  description = "Default AWS region from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
  type        = string
}

variable "default_oci_profile" {
  description = "Default OCI profile from base terraform.tfvars (null = OCI not used)"
  type        = string
  default     = null
}

variable "default_oci_region" {
  description = "Default OCI region from base terraform.tfvars (null = region from the OCI profile)"
  type        = string
  default     = null
}

variable "default_port_enabled" {
  description = "Default for wiring in the Port provider, from base terraform.tfvars"
  type        = bool
  default     = false
}

variable "default_fragments" {
  description = "Default fragments list from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
  type        = list(string)
}

variable "default_fragment_paths" {
  description = "Default extra fragment search paths from base terraform.tfvars (used when workspace file doesn't exist or doesn't override)"
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
