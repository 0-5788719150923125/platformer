# ArchOrchestrator Module Variables

# Core Variables (passed from root)
variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number"
  }
}

variable "aws_region" {
  description = "AWS region for ECR image URIs"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for destination ECR authentication"
  type        = string
}

# Per-deployment tenant lists (from entitlements system)
# Maps deployment name to list of entitled tenant codes
variable "tenants_by_deployment" {
  description = "Map of deployment name to entitled tenant list (from tenants module)"
  type        = map(list(string))
  default     = {}
}

# Service configuration from state fragment
# Each key is a named deployment (IO Cloud "instance") containing all infrastructure
variable "config" {
  description = "ArchOrchestrator deployment configurations - map of deployment name to deployment config"
  type = map(object({
    # ECS service definitions
    ecs = map(object({
      cpu           = number
      memory        = number
      image         = string # ECR image tag from source repo (e.g., "clario-5.2.0-alpha...")
      desired_count = optional(number, 1)
      port          = number                     # Container port
      architecture  = optional(string, "X86_64") # CPU architecture: X86_64 or ARM64
      protocol      = optional(string, "HTTP")   # Target group protocol: HTTP or HTTPS
      environment   = optional(map(string), {})  # User overrides for environment variables (module synthesizes defaults)
    }))

    # ECR source for image replication (pull from source, push to local ECR)
    ecr_source_profile    = optional(string, "acme-clario-cloud-dev")
    ecr_source_account_id = optional(string, "666666666666")
    ecr_source_region     = optional(string, "us-east-1")
    ecr_source_repo       = optional(string, "saas-us-east-1-deploymentecrrepository-7dc3wtgyh2tn")

    # RDS SQL Server configuration
    rds = optional(object({
      engine                  = optional(string, "sqlserver-se")
      engine_version          = string
      instance_class          = string
      allocated_storage       = number
      storage_type            = optional(string, "gp3")
      multi_az                = optional(bool, false)
      deletion_protection     = optional(bool, true)
      backup_retention_period = optional(number, 7)
    }))

    # S3 bucket definitions
    s3 = optional(list(object({
      purpose        = string
      lifecycle_days = optional(number, 90)
    })), [])

    # Network selection (defaults to first available)
    network = optional(string)
  }))
}

# Dependency inversion: networks and compute passed from root
variable "networks" {
  description = "Network module outputs"
  type        = any
}

variable "ecs_clusters" {
  description = "ECS clusters from compute module (keyed by purpose)"
  type        = any
  default     = {}
}

# Storage outputs (dependency inversion return path)
variable "rds_instances" {
  description = "RDS instances from storage module (keyed by purpose)"
  type        = any
  default     = {}
  sensitive   = true
}

variable "s3_buckets" {
  description = "S3 bucket names from storage module (keyed by purpose)"
  type        = map(string)
  default     = {}
}

# Access return-path variables (IAM resources managed by access module)
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
