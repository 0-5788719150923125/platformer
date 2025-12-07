# Access Module Variables
# Primary: accepts IAM access requests from modules (dependency inversion - access creates resources)
# Secondary: accepts security group and resource policy descriptions for reporting

variable "namespace" {
  description = "Deployment namespace for resource isolation and artifact naming"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for constructing IAM role ARNs in trust policies"
  type        = string
}

variable "aws_region" {
  description = "AWS region for S3 upload commands and console URLs"
  type        = string
  default     = ""
}

# Primary input: modules declare IAM access needs, access creates the resources
variable "access_requests" {
  description = "IAM access requests from modules (dependency inversion - access creates IAM resources)"
  type = list(object({
    module  = string # Source module name
    type    = string # "iam-role" or "inline-policy"
    purpose = string # Unique identifier within module

    # Role configuration (flat fields for type uniformity across modules)
    description         = optional(string, "")
    trust_services      = optional(list(string), [])
    trust_roles         = optional(list(string), [])
    trust_actions       = optional(list(string), ["sts:AssumeRole"])
    trust_conditions    = optional(string, "{}") # JSON-encoded (structure varies)
    managed_policy_arns = optional(list(string), [])
    inline_policies     = optional(map(string), {}) # policy name => JSON policy document
    instance_profile    = optional(bool, false)

    # Inline-policy request fields (for cross-module policies)
    role_key = optional(string, "")
    policy   = optional(string, "")
  }))
  default = []

  validation {
    condition = alltrue([
      for req in var.access_requests :
      contains(["iam-role", "inline-policy"], req.type)
    ])
    error_message = "access_requests type must be 'iam-role' or 'inline-policy'"
  }
}

# Temporary: modules not yet migrated to access_requests still emit V2 IAM role descriptions
# These are included in the report but NOT managed as resources by access
variable "iam_roles" {
  description = "IAM role descriptions from modules not yet migrated to access_requests (report-only)"
  type = list(object({
    module              = string
    role_name           = string
    description         = optional(string, "")
    trust_policy        = string
    managed_policy_arns = optional(list(string), [])
    inline_policies     = optional(map(string), {})
  }))
  default = []
}

variable "security_groups" {
  description = "Security group declarations from all modules with rules"
  type = list(object({
    module      = string
    group_name  = string
    description = optional(string, "")
    ingress = optional(list(object({
      description           = optional(string, "")
      protocol              = string
      from_port             = number
      to_port               = number
      cidr_blocks           = optional(list(string), [])
      source_security_group = optional(string, "")
      self                  = optional(bool, false)
    })), [])
    egress = optional(list(object({
      description = optional(string, "")
      protocol    = string
      from_port   = number
      to_port     = number
      cidr_blocks = optional(list(string), [])
    })), [])
  }))
  default = []
}

variable "resource_policies" {
  description = "Resource-level policies (S3 bucket policies, SQS queue policies)"
  type = list(object({
    module        = string
    resource_type = string
    resource_name = string
    policy        = string
  }))
  default = []
}
