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
  description = "Directories to search for state fragment YAML files, in priority order (first match wins). Absolute paths are used verbatim; relative paths resolve against this module. Every dir must exist."
  type        = list(string)
  default     = ["../states"]

  # A typo'd dir would otherwise be skipped silently, and a same-named
  # fragment from a later dir would load instead. fileexists() errors on a
  # directory and returns false for a missing path, so can() failing means
  # "this is a directory".
  validation {
    condition = alltrue([
      for dir in var.states_dirs :
      !can(fileexists(startswith(dir, "/") ? dir : "${path.module}/${dir}"))
    ])
    error_message = "States dir(s) not found: ${join(", ", [for dir in var.states_dirs : dir if can(fileexists(startswith(dir, "/") ? dir : "${path.module}/${dir}"))])}"
  }
}

variable "catalog_dirs" {
  description = "Directories whose fragments make up the available_states catalog, in priority order (first match wins). null = same as states_dirs. Lets callers keep test-only dirs searchable but out of catalogs."
  type        = list(string)
  default     = null
}

variable "aws_region" {
  description = "Current AWS region for deployment (used in validation error messages)"
  type        = string
  default     = "us-east-2"
}
