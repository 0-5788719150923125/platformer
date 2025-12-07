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

# Per-deployment tenant lists (from entitlements system)
# Maps deployment name to list of entitled tenant codes
variable "tenants_by_deployment" {
  description = "Map of deployment name to entitled tenant list (from tenants module)"
  type        = map(list(string))
  default     = {}
}

# Service configuration from state fragment
# Each key is a named deployment containing all infrastructure for that deployment
variable "config" {
  description = "Archshare deployment configurations - map of deployment name to deployment config"
  type = map(object({
    compute = optional(object({
      type = string # "ec2" or "eks"

      # EC2-specific fields
      ami_filter          = optional(string)
      ami_owner           = optional(string)
      instance_type       = optional(string, "t3.small")
      volume_size         = optional(number, 30)
      volume_type         = optional(string, "gp3")
      count               = optional(number, 1)
      user_data_script    = optional(string)
      subnet_tier         = optional(string)
      associate_public_ip = optional(bool, true)
      security_group_ids  = optional(list(string))
      ingress = optional(list(object({
        port     = number
        cidrs    = list(string)
        protocol = optional(string, "http")
      })))

      # EKS-specific fields
      version      = optional(string)
      support_type = optional(string, "STANDARD")
      vpc_id       = optional(string)
      subnet_ids   = optional(list(string))
      node_groups = optional(map(object({
        instance_types = list(string)
        min_size       = number
        max_size       = number
        desired_size   = number
        labels         = optional(map(string), {})
        taints = optional(list(object({
          key    = string
          value  = string
          effect = string
        })), [])
      })))
      addons                  = optional(list(string), [])
      endpoint_public_access  = optional(bool, false)
      endpoint_private_access = optional(bool, true)
      cluster_admins          = optional(list(string), [])

      # Common fields
      description  = optional(string, "")
      tags         = optional(map(string), {})
      network_name = optional(string)
      applications = optional(list(object({
        script        = optional(string)
        params        = optional(map(string), {})
        type          = optional(string, "ssm")
        playbook      = optional(string)
        playbook_file = optional(string)
        chart         = optional(string)
        repository    = optional(string)
        version       = optional(string)
        namespace     = optional(string, "default")
        release_name  = optional(string)
        values        = optional(string)
        wait          = optional(bool, true)
        timeout       = optional(number, 300)
      })), [])
    }))

    rds = optional(object({
      services = object({
        engine_version = string
        instance_class = string
        instances      = optional(number, 2)
      })
      storage = object({
        engine_version = string
        instance_class = string
        instances      = optional(number, 2)
      })
    }))

    elasticache = optional(object({
      services = object({
        engine                     = optional(string, "valkey")
        engine_version             = string
        node_type                  = string
        num_cache_nodes            = optional(number, 1)
        transit_encryption_enabled = optional(bool, false)
      })
      storage = object({
        engine                     = optional(string, "valkey")
        engine_version             = string
        node_type                  = string
        num_cache_nodes            = optional(number, 1)
        transit_encryption_enabled = optional(bool, false)
      })
      memcached = object({
        engine                     = optional(string, "memcached")
        engine_version             = string
        node_type                  = string
        num_cache_nodes            = optional(number, 1)
        transit_encryption_enabled = optional(bool, false)
      })
    }))

    ecr_registry = optional(string, "777777777777.dkr.ecr.us-east-2.amazonaws.com")
    network      = optional(string)
  }))
}

# Dependency inversion: networks passed from root
variable "networks" {
  description = "Network module outputs"
  type        = any
}

# Dependency inversion: compute security groups passed from root
variable "compute_security_groups" {
  description = "Compute module security groups (for DB/cache access)"
  type        = map(string)
  default     = {}
}

# Storage outputs (dependency inversion return path)
variable "rds_clusters" {
  description = "RDS clusters from storage module"
  type        = any
  default     = {}
  sensitive   = true
}

variable "elasticache_clusters" {
  description = "ElastiCache clusters from storage module"
  type        = any
  default     = {}
}

variable "s3_buckets" {
  description = "S3 buckets from storage module"
  type        = map(string)
  default     = {}
}

variable "efs_filesystems" {
  description = "EFS filesystems from storage module"
  type        = any
  default     = {}
}

# Storage security group IDs (for creating access rules)
variable "storage_enabled" {
  description = "Whether the storage module is active (plan-time-safe guard for SG rule for_each)"
  type        = bool
  default     = false
}

variable "storage_rds_security_group_id" {
  description = "RDS security group ID from storage module"
  type        = string
  default     = ""
}

variable "storage_elasticache_security_group_id" {
  description = "ElastiCache security group ID from storage module"
  type        = string
  default     = ""
}

# Compute instance role (for attaching ECR permissions)
variable "instance_role_name" {
  description = "IAM role name for compute instances (for attaching ECR pull permissions)"
  type        = string
  default     = ""
}

# EKS node role (for attaching ECR permissions)
variable "eks_node_role_name" {
  description = "EKS node group IAM role name for ECR permissions"
  type        = string
  default     = ""
}

# Kubeconfig readiness marker (for explicit dependency tracking)
variable "kubeconfig_ready" {
  description = "Map from compute module indicating kubeconfig contexts are ready"
  type        = any
  default     = {}
}

# EKS cluster security groups (for storage access rules)
variable "eks_cluster_security_groups" {
  description = "EKS cluster security groups from compute module (map: class_name => security_group_id)"
  type        = map(string)
  default     = {}
}
