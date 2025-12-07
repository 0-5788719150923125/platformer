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

variable "aws_profile" {
  description = "AWS CLI profile name for output commands"
  type        = string
}

variable "aws_region" {
  description = "AWS region for deployment (passed to Ansible playbooks)"
  type        = string
}

# Service Configuration
# All fields are optional with sensible defaults defined here
variable "config" {
  description = "Configuration management service configuration"
  type = object({
    # Global defaults for all documents
    # Default: Execute every 30 minutes
    schedule_expression         = optional(string, "rate(30 minutes)")
    parameter_store_prefix      = optional(string, "/password-rotation")
    parameter_username          = optional(string, "administrator")
    s3_output_bucket_enabled    = optional(bool, false)
    max_concurrency             = optional(string, "10%")
    max_errors                  = optional(string, "10%")
    compliance_severity         = optional(string, "HIGH")
    existing_instance_role_name = optional(string, "AWSSystemsManagerDefaultEC2InstanceManagementRole")

    # Ansible controller schedule (how often the CodeBuild controller runs)
    # Decoupled from SSM schedule_expression since Scheduler has no minimum interval
    ansible_schedule = optional(string, "rate(60 minutes)")

    # Per-document configuration overrides
    # Key is the document name (filename without .yaml extension)
    # Example: "windows-password-rotation" = {
    #   enabled = true,
    #   schedule_expression = "rate(1 hour)",
    #   max_concurrency = "25%",
    #   compliance_severity = "CRITICAL"
    # }
    # Note: Targets all SSM-managed instances via wildcard (InstanceIds = ["*"])
    documents = optional(map(object({
      enabled             = optional(bool, true)
      schedule_expression = optional(string)
      max_concurrency     = optional(string)
      max_errors          = optional(string)
      compliance_severity = optional(string)
      targets = optional(list(object({
        key    = string
        values = list(string)
      })))
      parameters = optional(map(string), {})
    })), {})

    # Patch management configuration (optional, auto-enables when baselines or maintenance_windows provided)
    # To disable: remove patch_management state fragment from states list
    # To temporarily disable a specific maintenance window: set its enabled = false
    patch_management = optional(object({
      baselines = optional(map(object({
        operating_system                  = string # "WINDOWS", "AMAZON_LINUX_2023", etc.
        approved_patches_compliance_level = string # "CRITICAL", "HIGH", "MEDIUM", "LOW"
        approved_patches                  = optional(list(string), [])
        rejected_patches                  = optional(list(string), [])
        approval_rules = optional(list(object({
          approve_after_days  = number
          compliance_level    = string
          enable_non_security = optional(bool, false)
          patch_filter = object({
            classification = optional(list(string), [])
            severity       = optional(list(string), [])
          })
        })), [])
        classes = optional(list(string), []) # Which compute classes use this baseline (empty = wildcard targeting via OS filters)
      })), {})

      maintenance_windows = optional(map(object({
        baseline = string # Reference to baselines map key
        schedule = string # cron() or rate() expression
        duration = number # Hours (1-24)
        cutoff   = number # Hours before end to stop new tasks (0 to duration-1)
        enabled  = optional(bool, true)
        # Task execution settings
        max_concurrency = optional(string, "25%") # Max instances to patch concurrently (e.g., "1", "5", "25%", "50%")
        max_errors      = optional(string, "10%") # Max errors before stopping (e.g., "1", "5", "10%", "25%")
        # Dynamic targeting via Lambda (queries SSM inventory - NO TAGS REQUIRED!)
        # Lambda automatically updates maintenance window targets based on SSM inventory filters
        dynamic_targeting = optional(object({
          platform_name    = string                           # OS name (e.g., "Rocky Linux")
          platform_version = string                           # OS version prefix (e.g., "9" matches 9.0, 9.1, 9.6, etc.)
          update_schedule  = optional(string, "rate(1 hour)") # How often to refresh target list
          max_instances    = optional(number, 50)             # Limit patching to N instances (controlled rollout). Uses consistent hashing for stable selection with minimal churn (~1 instance change per population change).
          # Application filtering (optional) - filters based on SSM inventory application data
          application_filters = optional(object({
            # Exclude instances with applications matching these patterns (glob-style wildcards)
            # Example: ["*redis*", "*postgresql*"] excludes any instance with Redis or PostgreSQL installed
            exclude_patterns = optional(list(string), [])
            # Include ONLY instances with applications matching these patterns (whitelist mode)
            # Example: ["nginx*", "httpd*"] includes only instances with nginx or httpd
            # NOTE: If specified, only instances WITH these apps are included
            include_patterns = optional(list(string), [])
          }))
        }))
        # Legacy: Tag-based targeting (optional fallback)
        target_tags = optional(map(list(string)))
      })), {})
      }), {
      baselines           = {}
      maintenance_windows = {}
    })

    # Hybrid activations for non-AWS machines (optional)
    # Enables SSM management of WSL instances, on-premises servers, VMs in other clouds
    # Example:
    #   developer-workstations = {
    #     description = "WSL instances on developer laptops"
    #     registration_limit = 5
    #   }
    # Names and tags auto-derived from key (cattle not pets)
    hybrid_activations = optional(map(object({
      description        = string
      instance_tier      = optional(string, "standard") # "standard" or "advanced"
      expiration_days    = optional(number, 7)          # Must be < 30 days (AWS limit)
      registration_limit = optional(number, 10)
    })), {})

    # Generic SSM associations for AWS-managed or external documents
    # Use this for associations to documents not in the documents/ directory
    # Examples: AWS-GatherSoftwareInventory, AWS-ConfigureAWSPackage, AWS-RunPatchBaseline, etc.
    #
    # IMPORTANT: max_concurrency and max_errors are only supported for Command/Automation documents
    # Policy documents (like AWS-GatherSoftwareInventory) do not support these parameters - omit them
    #
    # Example: Inventory collection (Policy document - no rate control parameters)
    #   inventory-collection = {
    #     document_name = "AWS-GatherSoftwareInventory"
    #     parameters = { applications = "Enabled", awsComponents = "Enabled" }
    #     targets = [{ key = "tag:Name", values = ["server1", "server2"] }]
    #   }
    #
    # Example: Install package (Command document - supports rate control)
    #   install-agent = {
    #     document_name = "AWS-ConfigureAWSPackage"
    #     max_concurrency = "10"
    #     max_errors = "5"
    #     parameters = { action = "Install", name = "AmazonCloudWatchAgent" }
    #     targets = [{ key = "InstanceIds", values = ["*"] }]
    #   }
    associations = optional(map(object({
      enabled             = optional(bool, true)
      document_name       = string
      schedule_expression = optional(string)
      max_concurrency     = optional(string) # Only for Command/Automation documents
      max_errors          = optional(string) # Only for Command/Automation documents
      compliance_severity = optional(string)
      parameters          = optional(map(string), {})
      targets = list(object({
        key    = string
        values = list(string)
      }))
    })), {})
  })
  default = {}

  validation {
    condition     = can(regex("^(cron\\(.+\\)|rate\\(.+\\))$", var.config.schedule_expression))
    error_message = "schedule_expression must be a valid cron() or rate() expression (e.g., 'rate(30 minutes)' or 'cron(0 0 ? * * *)')"
  }

  validation {
    condition     = can(regex("^/[a-zA-Z0-9/_-]+$", var.config.parameter_store_prefix))
    error_message = "parameter_store_prefix must start with / and contain only alphanumeric characters, dashes, underscores, and forward slashes"
  }

  validation {
    condition     = can(regex("^([0-9]+%?|[0-9]+)$", var.config.max_concurrency))
    error_message = "max_concurrency must be a number or percentage (e.g., '10' or '10%')"
  }

  validation {
    condition     = can(regex("^([0-9]+%?|[0-9]+)$", var.config.max_errors))
    error_message = "max_errors must be a number or percentage (e.g., '5' or '10%')"
  }

  validation {
    condition     = contains(["UNSPECIFIED", "LOW", "MEDIUM", "HIGH", "CRITICAL"], var.config.compliance_severity)
    error_message = "compliance_severity must be one of: UNSPECIFIED, LOW, MEDIUM, HIGH, CRITICAL"
  }

  # Per-document validation: schedule_expression
  validation {
    condition = alltrue([
      for doc_name, doc_config in var.config.documents :
      doc_config.schedule_expression == null ||
      can(regex("^(cron\\(.+\\)|rate\\(.+\\))$", doc_config.schedule_expression))
    ])
    error_message = "Document schedule_expression must be a valid cron() or rate() expression"
  }

  # Per-document validation: max_concurrency
  validation {
    condition = alltrue([
      for doc_name, doc_config in var.config.documents :
      doc_config.max_concurrency == null ||
      can(regex("^([0-9]+%?|[0-9]+)$", doc_config.max_concurrency))
    ])
    error_message = "Document max_concurrency must be a number or percentage"
  }

  # Per-document validation: max_errors
  validation {
    condition = alltrue([
      for doc_name, doc_config in var.config.documents :
      doc_config.max_errors == null ||
      can(regex("^([0-9]+%?|[0-9]+)$", doc_config.max_errors))
    ])
    error_message = "Document max_errors must be a number or percentage"
  }

  # Per-document validation: compliance_severity
  validation {
    condition = alltrue([
      for doc_name, doc_config in var.config.documents :
      doc_config.compliance_severity == null ||
      contains(["UNSPECIFIED", "LOW", "MEDIUM", "HIGH", "CRITICAL"], doc_config.compliance_severity)
    ])
    error_message = "Document compliance_severity must be one of: UNSPECIFIED, LOW, MEDIUM, HIGH, CRITICAL"
  }

  # Per-document validation: parameter key format
  validation {
    condition = alltrue([
      for doc_name, doc_config in var.config.documents :
      alltrue([
        for param_key, param_val in doc_config.parameters :
        can(regex("^[A-Za-z][A-Za-z0-9]*$", param_key))
      ])
    ])
    error_message = "Parameter keys must start with a letter and contain only alphanumeric characters"
  }

  # Patch management validation: operating_system
  validation {
    condition = alltrue([
      for baseline_name, baseline in var.config.patch_management.baselines :
      contains([
        "WINDOWS",
        "AMAZON_LINUX",
        "AMAZON_LINUX_2",
        "AMAZON_LINUX_2023",
        "UBUNTU",
        "REDHAT_ENTERPRISE_LINUX",
        "SUSE",
        "CENTOS",
        "ORACLE_LINUX",
        "DEBIAN",
        "MACOS",
        "RASPBIAN",
        "ROCKY_LINUX"
      ], baseline.operating_system)
    ])
    error_message = "Patch baseline operating_system must be one of: WINDOWS, AMAZON_LINUX, AMAZON_LINUX_2, AMAZON_LINUX_2023, UBUNTU, REDHAT_ENTERPRISE_LINUX, SUSE, CENTOS, ORACLE_LINUX, DEBIAN, MACOS, RASPBIAN, ROCKY_LINUX"
  }

  # Patch management validation: approved_patches_compliance_level
  validation {
    condition = alltrue([
      for baseline_name, baseline in var.config.patch_management.baselines :
      contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNSPECIFIED"],
      baseline.approved_patches_compliance_level)
    ])
    error_message = "Patch baseline approved_patches_compliance_level must be one of: CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED"
  }

  # Patch management validation: approval rule compliance_level
  validation {
    condition = alltrue(flatten([
      for baseline_name, baseline in var.config.patch_management.baselines : [
        for rule in baseline.approval_rules :
        contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNSPECIFIED"], rule.compliance_level)
      ]
    ]))
    error_message = "Patch baseline approval rule compliance_level must be one of: CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED"
  }

  # Patch management validation: maintenance window schedule
  validation {
    condition = alltrue([
      for window in var.config.patch_management.maintenance_windows :
      can(regex("^(cron\\(.+\\)|rate\\(.+\\))$", window.schedule))
    ])
    error_message = "Maintenance window schedule must be a valid cron() or rate() expression"
  }

  # Patch management validation: maintenance window duration
  validation {
    condition = alltrue([
      for window in var.config.patch_management.maintenance_windows :
      window.duration >= 1 && window.duration <= 24
    ])
    error_message = "Maintenance window duration must be between 1 and 24 hours"
  }

  # Patch management validation: maintenance window cutoff
  validation {
    condition = alltrue([
      for window in var.config.patch_management.maintenance_windows :
      window.cutoff >= 0 && window.cutoff < window.duration
    ])
    error_message = "Maintenance window cutoff must be between 0 and duration-1"
  }

  # Patch management validation: baseline references exist
  validation {
    condition = alltrue([
      for window in var.config.patch_management.maintenance_windows :
      contains(keys(var.config.patch_management.baselines), window.baseline)
    ])
    error_message = "Maintenance window baseline must reference an existing baseline in the baselines map"
  }

  # Hybrid activation validation: expiration_days must be < 30 (AWS limit)
  validation {
    condition = alltrue([
      for activation_name, activation in var.config.hybrid_activations :
      activation.expiration_days > 0 && activation.expiration_days < 30
    ])
    error_message = "Hybrid activation expiration_days must be greater than 0 and less than 30 days (AWS limit)"
  }

  # Wildcard targeting validation: if classes is empty, must have dynamic_targeting or target_tags
  validation {
    condition = alltrue([
      for window in var.config.patch_management.maintenance_windows :
      length(var.config.patch_management.baselines[window.baseline].classes) > 0 ||
      window.dynamic_targeting != null ||
      window.target_tags != null
    ])
    error_message = "Maintenance windows with wildcard targeting (empty classes list) must specify either dynamic_targeting (recommended - no tags required) or target_tags for instance filtering"
  }

  # Application filters validation: if specified, must have at least one pattern
  validation {
    condition = alltrue([
      for window in var.config.patch_management.maintenance_windows :
      window.dynamic_targeting == null ||
      window.dynamic_targeting.application_filters == null ||
      (
        length(coalesce(window.dynamic_targeting.application_filters.exclude_patterns, [])) > 0 ||
        length(coalesce(window.dynamic_targeting.application_filters.include_patterns, [])) > 0
      )
    ])
    error_message = "If application_filters is specified, at least one of exclude_patterns or include_patterns must be non-empty"
  }

  # Generic associations validation: schedule_expression format
  validation {
    condition = alltrue([
      for assoc_name, assoc_config in var.config.associations :
      assoc_config.schedule_expression == null ||
      can(regex("^(cron\\(.+\\)|rate\\(.+\\))$", assoc_config.schedule_expression))
    ])
    error_message = "Association schedule_expression must be a valid cron() or rate() expression"
  }

  # Generic associations validation: max_concurrency format
  validation {
    condition = alltrue([
      for assoc_name, assoc_config in var.config.associations :
      assoc_config.max_concurrency == null ||
      can(regex("^([0-9]+%?|[0-9]+)$", assoc_config.max_concurrency))
    ])
    error_message = "Association max_concurrency must be a number or percentage"
  }

  # Generic associations validation: max_errors format
  validation {
    condition = alltrue([
      for assoc_name, assoc_config in var.config.associations :
      assoc_config.max_errors == null ||
      can(regex("^([0-9]+%?|[0-9]+)$", assoc_config.max_errors))
    ])
    error_message = "Association max_errors must be a number or percentage"
  }

  # Generic associations validation: compliance_severity values
  validation {
    condition = alltrue([
      for assoc_name, assoc_config in var.config.associations :
      assoc_config.compliance_severity == null ||
      contains(["UNSPECIFIED", "LOW", "MEDIUM", "HIGH", "CRITICAL"], assoc_config.compliance_severity)
    ])
    error_message = "Association compliance_severity must be one of: UNSPECIFIED, LOW, MEDIUM, HIGH, CRITICAL"
  }

  # Generic associations validation: must have at least one target
  validation {
    condition = alltrue([
      for assoc_name, assoc_config in var.config.associations :
      !assoc_config.enabled || length(assoc_config.targets) > 0
    ])
    error_message = "Enabled associations must have at least one target defined"
  }
}

# S3 bucket for SSM association logs (populated from storage module via dependency inversion)
variable "ssm_association_log_bucket" {
  description = "S3 bucket name for SSM association logs (provided by storage module)"
  type        = string
  default     = ""
}

# S3 bucket for hook scripts (populated from storage module via dependency inversion)
variable "hooks_bucket" {
  description = "S3 bucket name for hook scripts (provided by storage module)"
  type        = string
  default     = ""
}

# Instances grouped by class (populated from compute module via dependency inversion)
variable "instances_by_class" {
  description = "Instances grouped by class name — map of class_name => { instance_key => instance_id } (provided by compute module)"
  type        = map(map(string))
  default     = {}
}

# Application requests (populated from applications module via dependency inversion)
# All types of application requests - this module filters internally by type
variable "application_requests" {
  description = "All application deployment requests from applications module - filtered internally by type (ssm, ansible, user-data, helm)"
  type = list(object({
    class  = string
    type   = string
    params = optional(map(string))

    # Target selection
    target_tag_key   = optional(string)
    target_tag_value = optional(string)

    # SSM-specific fields (optional)
    script             = optional(string)
    script_source_path = optional(string)

    # Ansible-specific fields (optional)
    tenant               = optional(string)
    playbook             = optional(string)
    playbook_file        = optional(string)
    playbook_source_path = optional(string)

    # Targeting fields (for standalone applications and cluster mode)
    targeting_mode = optional(string, "compute") # "compute" | "wildcard" | "tags" | "instance" | "cluster"
    targets = optional(list(object({
      key    = string
      values = list(string)
    })))

    # Direct instance targeting (for mode: 1-master cluster requests)
    instance_id = optional(string) # EC2 instance ID — used when targeting_mode = "instance"

    # Cluster targeting (for mode: 1-master) — all nodes in one Ansible invocation
    hosts = optional(list(object({
      instance_id = string
      vars        = optional(map(string), {})
    })))

    # Helm-specific fields (optional - not used by this module)
    chart        = optional(string)
    repository   = optional(string)
    version      = optional(string)
    namespace    = optional(string)
    release_name = optional(string)
    values       = optional(string)
    wait         = optional(bool)
    timeout      = optional(number)

    # User-data-specific fields (optional - not used by this module)
    # (none currently)
  }))
  default = []
}

# Whether application deployments exist (drives bucket request without depending on application_requests)
# The root computes this from config alone, avoiding a dependency cycle:
#   build ← storage ← config-mgmt.bucket_requests ← compute ← build
variable "has_application_deployments" {
  description = "Whether any application deployments (SSM/Ansible) exist — drives application-scripts bucket request"
  type        = bool
  default     = false
}

# Scripts bucket for application installation (from storage module via dependency inversion)
variable "application_scripts_bucket" {
  description = "S3 bucket name for application scripts (provided by storage module)"
  type        = string
  default     = ""
}

# Instance role for SSM-based application deployment (from compute module)
variable "instances_role_name" {
  description = "IAM role name for compute instances (for attaching S3 access policy)"
  type        = string
  default     = ""
}

variable "instances_role_arn" {
  description = "IAM role ARN for compute instances (for S3 bucket policy)"
  type        = string
  default     = ""
}

# Scheduled Lambda function requests from external modules (dependency inversion)
# Portal module defines Lambda requirements; this module creates the actual AWS resources
variable "lambda_requests" {
  description = "Scheduled Lambda function requests from external modules (dependency inversion)"
  type = list(object({
    name        = string
    handler     = string
    runtime     = string
    timeout     = number
    schedule    = string
    source_path = string
    environment = map(string)
    iam_statements = list(object({
      actions   = list(string)
      resources = list(string)
    }))
  }))
  default = []
}

# Event bus webhooks from portal module (dependency inversion)
variable "event_bus_webhooks" {
  description = "Event bus webhook URLs from portal module (dependency inversion)"
  type        = map(string)
  default     = {}
}

# AWS SSO start URL for console link wrapping
variable "aws_sso_start_url" {
  description = "AWS SSO start URL for console link wrapping"
  type        = string
  default     = ""
}

# Config-derived flag for access_requests output only.
# Indicates whether ansible application requests exist (from applications module, not cluster).
# MUST be computed from config-only sources in root to avoid module-closure cycles.
variable "ansible_applications_configured" {
  description = "Config-derived flag: are there ansible application requests (used in access_requests to avoid cycle)"
  type        = bool
  default     = false
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
