variable "states" {
  description = <<-EOT
    List of state fragments to load and merge from states/ directory.
    State fragments are YAML files that define service configurations.

    States are deep-merged in order (left-to-right).

    State fragments may contain a 'matrix' key for CI/CD regions and
    tenant targeting dimensions. Terraform deploys to ONE region at a
    time; multi-region deployments are orchestrated externally by CI/CD.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.states : can(regex("^[a-z0-9-]+$", s))])
    error_message = "State names must contain only lowercase letters, numbers, and hyphens"
  }
}


variable "states_dirs" {
  description = "Directories to search for state fragment YAML files (first match wins)"
  type        = list(string)
  default     = ["../states"]
}

variable "aws_region" {
  description = "Current AWS region for deployment (used in validation error messages)"
  type        = string
}
