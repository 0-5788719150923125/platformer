variable "namespace" {
  type        = string
  description = "Unique deployment identifier for resource naming and tagging"
}

variable "config" {
  type = object({
    atlassian_base_url       = string
    atlassian_email          = string
    project_keys             = list(string)
    ai_backend               = optional(string, "test")
    debug                    = optional(bool, false)
    system_prompt            = optional(string, "")
    response_rate            = optional(number, 0.25)
    bedrock_model_id         = optional(string, "us.anthropic.claude-haiku-4-5-20251001-v1:0")
    bedrock_max_tokens       = optional(number, 512)
    bedrock_temperature      = optional(number, 0.3)
    queue_visibility_timeout = optional(number, 300)
    lambda_timeout           = optional(number, 300)
    lambda_memory            = optional(number, 512)
    devin_poll_interval      = optional(number, 15)
    devin_max_wait           = optional(number, 720)

    # Knowledge Base (RAG) configuration
    knowledge_base_enabled     = optional(bool, false)
    embedding_model_id         = optional(string, "amazon.titan-embed-text-v2:0")
    kb_max_results             = optional(number, 5)
    kb_chunking_strategy       = optional(string, "SEMANTIC")
    kb_document_paths          = optional(list(string), [])
    kb_supported_extensions    = optional(list(string), [".md", ".txt", ".pdf", ".html", ".htm", ".docx", ".doc", ".csv"])
    kb_remap_to_txt_extensions = optional(list(string), [".tf", ".hcl", ".yml", ".yaml"])

    # Deny list - arbitrary strings (names, emails, topics) the bot should not engage with.
    # If any of these appear in ticket content, the bot replies with [NO_RESPONSE].
    deny_list = optional(list(string), [])
  })
  description = "archbot service configuration from state fragment"

  validation {
    condition     = contains(["devin", "bedrock", "test"], var.config.ai_backend)
    error_message = "ai_backend must be one of: devin, bedrock, test"
  }

  validation {
    condition     = contains(["SEMANTIC", "FIXED_SIZE", "NONE", "HIERARCHICAL"], var.config.kb_chunking_strategy)
    error_message = "kb_chunking_strategy must be one of: SEMANTIC, FIXED_SIZE, NONE, HIERARCHICAL"
  }
}

variable "atlassian_secret_arn" {
  type        = string
  description = "ARN of the replicated Atlassian PAT in Secrets Manager (from secrets module)"
}

variable "devin_secret_arn" {
  type        = string
  description = "ARN of the replicated Devin API key in Secrets Manager (from secrets module)"
}

variable "aws_profile" {
  type        = string
  description = "AWS CLI profile name for provisioner scripts (KB index creation, ingestion jobs)"
  default     = ""
}

variable "kb_documents_bucket_trigger" {
  type        = string
  description = "Replacement sentinel from storage module - changes when the KB documents bucket is recreated"
  default     = ""
}

variable "kb_documents_bucket_name" {
  type        = string
  description = "KB documents S3 bucket name from storage module (dependency inversion)"
  default     = ""
}

variable "kb_documents_bucket_arn" {
  type        = string
  description = "KB documents S3 bucket ARN from storage module (dependency inversion)"
  default     = ""
}

variable "event_bus_webhooks" {
  type        = map(string)
  description = "Event bus webhook URLs from portal module"
  default     = {}
}

# Access return-path (IAM resources created by access module)
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
