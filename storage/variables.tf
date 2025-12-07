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

# bucket_requests interface (dependency inversion)
variable "bucket_requests" {
  description = "Bucket definitions from other modules (storage module creates resources)"
  type = list(object({
    purpose             = string
    description         = string
    versioning_enabled  = optional(bool, false)
    lifecycle_days      = optional(number, 90)
    glacier_days        = optional(number, null)
    intelligent_tiering = optional(bool, false)
    access_logging      = optional(bool, true) # Default: enabled (opt-out)
    prefix              = optional(string, "")
    cors_enabled        = optional(bool, false)
    public_access       = optional(bool, false)
    force_destroy       = optional(bool, true) # Default: enabled for easy destruction
    # Optional: run a command immediately after bucket creation (e.g., seed upload)
    # on_create_command is the shell command to execute.
    # upload_trigger is an opaque string whose change causes the command to re-run;
    # requesters typically set this to a resource ID so Terraform carries the dependency.
    on_create_command = optional(string)
    upload_trigger    = optional(string)
  }))
  default = []

  validation {
    condition = length(var.bucket_requests) == length(distinct([
      for req in var.bucket_requests : req.purpose
    ]))
    error_message = "bucket_requests must have unique 'purpose' values"
  }
}

# rds_cluster_requests interface (dependency inversion)
# Unified interface for both Aurora clusters and standalone RDS instances
variable "rds_cluster_requests" {
  description = "RDS cluster/instance requests from other modules (storage module creates resources based on type)"
  type = list(object({
    purpose = string # Unique identifier for outputs/lookup
    type    = string # "aurora" or "standalone"
    name    = string

    # Common fields (both aurora and standalone)
    engine                     = optional(string, "aurora-postgresql") # aurora-postgresql, aurora-mysql, sqlserver-se, postgres, mysql, etc.
    engine_version             = string
    instance_class             = string
    vpc_id                     = string
    subnet_ids                 = list(string)
    allowed_security_group_ids = optional(list(string), [])
    deletion_protection        = optional(bool, true)
    backup_retention_period    = optional(number, 7)

    # Aurora-specific fields (ignored for standalone)
    database_name  = optional(string) # Aurora cluster database name
    instances      = optional(number, 2)
    final_snapshot = optional(bool, true)

    # Standalone-specific fields (ignored for aurora)
    allocated_storage = optional(number) # Storage in GB
    storage_type      = optional(string, "gp3")
    iops              = optional(number, null)
    multi_az          = optional(bool, false)
  }))
  default = []

  validation {
    condition = length(var.rds_cluster_requests) == length(distinct([
      for req in var.rds_cluster_requests : req.purpose
    ]))
    error_message = "rds_cluster_requests must have unique 'purpose' values"
  }

  validation {
    condition = alltrue([
      for req in var.rds_cluster_requests :
      contains(["aurora", "standalone"], req.type)
    ])
    error_message = "rds_cluster_requests type must be either 'aurora' or 'standalone'"
  }
}

# elasticache_cluster_requests interface (dependency inversion)
variable "elasticache_cluster_requests" {
  description = "ElastiCache cluster requests from other modules (storage module creates resources)"
  type = list(object({
    purpose                    = string # Unique identifier
    engine                     = string # "valkey" or "memcached"
    engine_version             = string
    node_type                  = string
    num_cache_nodes            = number
    transit_encryption_enabled = optional(bool, false)
    subnet_ids                 = list(string)
    vpc_id                     = string
    allowed_security_group_ids = optional(list(string), [])
  }))
  default = []

  validation {
    condition = length(var.elasticache_cluster_requests) == length(distinct([
      for req in var.elasticache_cluster_requests : req.purpose
    ]))
    error_message = "elasticache_cluster_requests must have unique 'purpose' values"
  }
}

# repository_requests interface (dependency inversion)
variable "repository_requests" {
  description = "CodeCommit repository requests from other modules (storage module creates resources)"
  type = list(object({
    purpose           = string
    description       = string
    type              = optional(string, "codecommit")
    default_branch    = optional(string, "main")
    on_create_command = optional(string)
    commit_trigger    = optional(string)
  }))
  default = []

  validation {
    condition = length(var.repository_requests) == length(distinct([
      for req in var.repository_requests : req.purpose
    ]))
    error_message = "repository_requests must have unique 'purpose' values"
  }

  validation {
    condition     = alltrue([for req in var.repository_requests : contains(["codecommit"], req.type)])
    error_message = "repository_requests type must be one of: codecommit"
  }
}

variable "aws_profile" {
  description = "AWS CLI profile for post-creation commands"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region for post-creation commands"
  type        = string
  default     = ""
}
