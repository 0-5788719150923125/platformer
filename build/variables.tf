# Core Variables
variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile for Packer and S3 operations"
  type        = string
  default     = ""
}

variable "config" {
  description = "Compute service configuration - map of class name to class definition (filtered to build: true internally)"
  type        = any
  default     = {}
}

variable "standalone_applications" {
  description = "Standalone application definitions (services.applications) for golden AMI inclusion"
  type        = any
  default     = {}
}

variable "vpc_id" {
  description = "VPC ID for Packer build instances (default network)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for Packer build instances (default network public subnet)"
  type        = string
}

variable "application_scripts_bucket" {
  description = "S3 bucket name for application scripts/playbooks (from storage module)"
  type        = string
  default     = ""
}

# Access return-path variables (IAM resources managed by access module)
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
