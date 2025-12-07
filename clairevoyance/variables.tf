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

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile name for authentication"
  type        = string
}

# Service Configuration
# All fields are optional with sensible defaults defined here
variable "config" {
  description = "ClaireVoyance medical AI platform configuration"
  type = object({
    # SageMaker Studio configuration
    studio_instance_type = optional(string, "ml.t3.medium")

    # SageMaker Notebook configuration
    notebook_instance_type = optional(string, "ml.g5.2xlarge") # NVIDIA A10G, 24GB VRAM
    notebook_volume_size   = optional(number, 512)             # GB for Docker storage

    # Inference endpoint configuration
    inference_instance_type = optional(string, "ml.g5.2xlarge")
    inference_models = optional(list(object({
      model_name     = string              # medgemma, chexagent, medsam2, classifier
      instance_type  = optional(string)    # Override global inference_instance_type
      instance_count = optional(number, 1) # Number of instances for this model
    })), [])                               # Default: no endpoints deployed

    # ECR repository configuration
    ecr_repositories = optional(list(string), ["ml-models"])

    # DNS and SSL configuration
    domain_name       = optional(string, "*.dev-platform.example.com")
    route53_zone_name = optional(string, "dev-platform.example.com")
  })
  default = {}

  # Validation: model names must be valid
  validation {
    condition = alltrue([
      for model in var.config.inference_models :
      contains(["medgemma", "chexagent", "medsam2", "classifier"], model.model_name)
    ])
    error_message = "model_name must be one of: medgemma, chexagent, medsam2, classifier"
  }

  # Validation: instance types must be valid format
  validation {
    condition     = can(regex("^ml\\.[a-z][0-9]\\.[0-9]?[a-z]+$", var.config.studio_instance_type))
    error_message = "studio_instance_type must be valid SageMaker instance type format (e.g., 'ml.t3.medium')"
  }

  validation {
    condition     = can(regex("^ml\\.[a-z][0-9]\\.[0-9]?[a-z]+$", var.config.notebook_instance_type))
    error_message = "notebook_instance_type must be valid SageMaker instance type format (e.g., 'ml.g5.2xlarge')"
  }

  validation {
    condition     = can(regex("^ml\\.[a-z][0-9]\\.[0-9]?[a-z]+$", var.config.inference_instance_type))
    error_message = "inference_instance_type must be valid SageMaker instance type format (e.g., 'ml.g5.2xlarge')"
  }

  # Validation: per-model instance type overrides
  validation {
    condition = alltrue([
      for model in var.config.inference_models :
      model.instance_type == null || can(regex("^ml\\.[a-z][0-9]\\.[0-9]?[a-z]+$", model.instance_type))
    ])
    error_message = "model instance_type override must be valid SageMaker instance type format"
  }

  # Validation: notebook volume size reasonable range
  validation {
    condition     = var.config.notebook_volume_size >= 5 && var.config.notebook_volume_size <= 16384
    error_message = "notebook_volume_size must be between 5 and 16384 GB"
  }

  # Validation: instance count reasonable range
  validation {
    condition = alltrue([
      for model in var.config.inference_models :
      model.instance_count >= 1 && model.instance_count <= 10
    ])
    error_message = "model instance_count must be between 1 and 10"
  }

  # Validation: domain name format
  validation {
    condition     = can(regex("^\\*\\..+\\..+$", var.config.domain_name))
    error_message = "domain_name must be a wildcard domain (e.g., '*.dev-platform.example.com')"
  }

  # Validation: route53 zone name format
  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]+$", var.config.route53_zone_name))
    error_message = "route53_zone_name must be a valid domain name (e.g., 'dev-platform.example.com')"
  }
}
