# Auto-docs module variables
# This module generates documentation from variables.tf files across the project

variable "project_root" {
  description = "Path to project root directory"
  type        = string
  default     = ".."
}

variable "output_file" {
  description = "Path to output schema file (relative to project root)"
  type        = string
  default     = "SCHEMA.md"
}

variable "readme_file" {
  description = "Path to README file to update (relative to project root)"
  type        = string
  default     = "README.md"
}
