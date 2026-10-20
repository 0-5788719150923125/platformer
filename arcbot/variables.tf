variable "namespace" {
  type        = string
  description = "Unique deployment identifier for resource naming and tagging"
}

variable "config" {
  type = map(object({
    target = string # "atlassian" or "discord"

    # Common fields. The default model, Claude Haiku 5.5, thinks by default
    # (thinking counts toward bedrock_max_tokens) and rejects any non-default
    # temperature, so bedrock_temperature defaults to null (not sent).
    ai_backend          = optional(string, "bedrock")
    debug               = optional(bool, false)
    system_prompt       = optional(string, "")
    response_rate       = optional(number, 0.25)
    bedrock_model_id    = optional(string, "us.anthropic.claude-haiku-5-5")
    bedrock_max_tokens  = optional(number, 4096)
    bedrock_temperature = optional(number)
    deny_list           = optional(list(string), [])

    # Image generation (generate_image tool). Separate region knob because the
    # active text-to-image models (Stability core/ultra/sd3.5) live in us-west-2
    # only; Amazon's Nova Canvas / Titan Image are Legacy (provider-locked).
    image_model_id     = optional(string, "stability.stable-image-core-v1:1")
    image_model_region = optional(string, "us-west-2")

    # Atlassian-specific (when target = "atlassian")
    atlassian_base_url       = optional(string)
    atlassian_email          = optional(string)
    project_keys             = optional(list(string), [])
    queue_visibility_timeout = optional(number, 300)
    lambda_timeout           = optional(number, 300)
    lambda_memory            = optional(number, 512)
    devin_poll_interval      = optional(number, 15)
    devin_max_wait           = optional(number, 720)

    # Discord-specific (when target = "discord")
    discord_nickname      = optional(string)
    discord_history_limit = optional(number, 20)
    discord_tool_channels = optional(list(string), [])

    # Knowledge Base (RAG) configuration
    knowledge_base_enabled  = optional(bool, false)
    embedding_model_id      = optional(string, "amazon.titan-embed-text-v2:0")
    kb_max_results          = optional(number, 5)
    kb_chunking_strategy    = optional(string, "SEMANTIC")
    kb_document_paths       = optional(list(string), [])
    kb_supported_extensions = optional(list(string), [".md", ".txt", ".pdf", ".html", ".htm", ".docx", ".doc", ".csv"])

    # Files outside kb_supported_extensions upload as .txt when their content
    # is text, and are skipped when it's binary. These globs skip files on top
    # of the built-in lockfile and minified-bundle patterns: one containing '/'
    # matches the S3 key ("praxis/docs/x.md"; "./" sources have no prefix), any
    # other matches the file name in any directory.
    kb_exclude_patterns = optional(list(string), [])

    # Seconds between scans by the local KB sync daemon, which uploads changed
    # documents and re-indexes on its own. 0 = no daemon: documents upload and
    # re-index during terraform apply instead.
    kb_sync_interval = optional(number, 0)
  }))
  description = "Map of bot configurations keyed by bot name, with target type discriminator"

  validation {
    condition = alltrue([
      for n, b in var.config : contains(["atlassian", "discord"], b.target)
    ])
    error_message = "Each bot target must be one of: atlassian, discord"
  }

  validation {
    condition = alltrue([
      for n, b in var.config : contains(["devin", "bedrock", "test"], b.ai_backend)
    ])
    error_message = "ai_backend must be one of: devin, bedrock, test"
  }

  validation {
    condition = alltrue([
      for n, b in var.config : contains(["SEMANTIC", "FIXED_SIZE", "NONE", "HIERARCHICAL"], b.kb_chunking_strategy)
    ])
    error_message = "kb_chunking_strategy must be one of: SEMANTIC, FIXED_SIZE, NONE, HIERARCHICAL"
  }

  validation {
    condition = alltrue([
      for n, b in var.config : b.kb_sync_interval == 0 || b.kb_sync_interval >= 60
    ])
    error_message = "kb_sync_interval must be 0 (disabled) or at least 60 seconds"
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
