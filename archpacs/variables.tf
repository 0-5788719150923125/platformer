# ArchPACS Module Variables

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
  description = "ArchPACS deployment configurations - map of deployment name to deployment config"
  type = map(object({
    # Maestro configuration for PACS installation
    maestro = optional(object({
      pacs_version       = string                         # e.g., "PACS-5-8-1-R32"
      iv_version         = optional(string)               # e.g., "5-8-1-R32" (defaults to pacs_version)
      orchestrator_class = string                         # Compute class that hosts the Maestro orchestrator
      client_code        = optional(string, "PLATFORMER") # Client code for distribute.cfg
    }))

    compute = optional(map(object({
      type = string # "ec2" or "eks"

      # PACS server type for Maestro distribute.cfg (e.g., "ModalityWithDiskmon", "DicomMasterService")
      server_type = optional(string)

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
    })), {})

    rds = optional(object({
      lifimage_cns = object({
        engine_version          = string
        instance_class          = string
        instances               = number
        database_name           = string
        deletion_protection     = optional(bool, false)
        backup_retention_period = optional(number, 7)
      })
    }))

    s3 = optional(list(object({
      purpose        = string
      versioning     = optional(bool, false)
      lifecycle      = optional(map(number))
      retention_days = optional(number)
    })))
  }))
}

variable "namespace" {
  description = "Namespace for resource naming"
  type        = string
}

variable "networks" {
  description = "Available networks from networking module"
  type        = map(any)
}
