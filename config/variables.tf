variable "fragments" {
  description = <<-EOT
    List of fragments to load and merge from fragments/ directory.
    Fragments are YAML files that define service configurations.

    Fragments are deep-merged in order (left-to-right).

    Fragments may contain a 'matrix' key for CI/CD regions and
    tenant targeting dimensions. Terraform deploys to ONE region at a
    time; multi-region deployments are orchestrated externally by CI/CD.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.fragments : can(regex("^[a-z0-9-]+$", s))])
    error_message = "Fragment names must contain only lowercase letters, numbers, and hyphens"
  }
}


variable "fragment_dirs" {
  description = "Directories to search for fragment YAML files, in priority order (first match wins). Absolute paths are used verbatim; relative paths resolve against this module. Every dir must exist."
  type        = list(string)
  default     = ["../fragments"]

  # A typo'd dir would otherwise be skipped silently, and a same-named
  # fragment from a later dir would load instead. fileexists() errors on a
  # directory and returns false for a missing path, so can() failing means
  # "this is a directory".
  validation {
    condition = alltrue([
      for dir in var.fragment_dirs :
      !can(fileexists(startswith(dir, "/") ? dir : "${path.module}/${dir}"))
    ])
    error_message = "Fragment dir(s) not found: ${join(", ", [for dir in var.fragment_dirs : dir if can(fileexists(startswith(dir, "/") ? dir : "${path.module}/${dir}"))])}"
  }
}

variable "catalog_dirs" {
  description = "Directories whose fragments make up the available_fragments catalog, in priority order (first match wins). null = same as fragment_dirs. Lets callers keep test-only dirs searchable but out of catalogs."
  type        = list(string)
  default     = null
}

variable "aws_region" {
  description = "Current AWS region for deployment (used in validation error messages)"
  type        = string
  default     = "us-east-2"
}
