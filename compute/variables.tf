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
  description = "AWS CLI profile for Helm ECR authentication in local-exec provisioners"
  type        = string
  default     = ""
}

# Tenant Validation (from tenants module via dependency inversion)
variable "valid_tenants" {
  description = "List of valid active tenants from tenants module (for validation)"
  type        = list(string)
  default     = []
}

# Network Module Outputs (dependency inversion)
variable "networks" {
  description = "Map of network name to network module outputs (for multi-VPC support)"
  type        = map(any)
  default     = {}
}

# Per-class tenant lists from entitlements system
variable "tenants_by_class" {
  description = "Map of class name to entitled tenant list (from tenants module)"
  type        = map(list(string))
  default     = {}
}

# Service Configuration
variable "config" {
  description = "Compute service configuration - map of class name to class definition"
  type = map(object({
    type = string # REQUIRED: "ec2", "eks", "ecs", or "localhost" - determines compute implementation

    # Network selection (applies to all compute types)
    network_name = optional(string) # Name of network to use (from networks map). If null, uses default VPC.

    # EC2-specific fields (when type = "ec2")
    ami_ssm_parameter   = optional(string)             # SSM parameter path for AMI ID (e.g., "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64") - deterministic, AWS-maintained
    ami_filter          = optional(string)             # AWS AMI name filter (e.g., "Windows_Server-2022-*") - fallback when SSM parameter unavailable
    ami_owner           = optional(string)             # AWS account ID that owns the AMI (defaults to "amazon", only used with ami_filter)
    instance_type       = optional(string, "t3.small") # Instance type (default: t3.small)
    volume_size         = optional(number, 30)         # Root volume size in GB (default: 30)
    volume_type         = optional(string, "gp3")      # Root volume type (default: gp3)
    count               = optional(number, 1)          # Number of instances per tenant (default: 1)
    user_data_script    = optional(string)             # Name of user_data script in scripts/ directory (e.g., "rocky9-ssm-agent.sh")
    subnet_tier         = optional(string)             # Subnet tier: "public", "private", or "intra" (default: "private")
    associate_public_ip = optional(bool, true)         # Associate public IP address (default: true to match default VPC behavior)
    security_group_ids  = optional(list(string))       # Additional security group IDs (beyond default compute security group)
    ingress = optional(list(object({                   # Ingress rules (direct SG rules for http, ALB for https)
      port     = number                                # Port to allow ingress on
      cidrs    = list(string)                          # CIDR blocks to allow ingress from
      protocol = optional(string, "http")              # "http" (direct SG rule) or "https" (ALB with TLS termination)
    })))
    build        = optional(bool, false)      # Build golden AMI via ImageBuilder before launching instances
    swap_size    = optional(number, 0)        # Swap file size in GB (0 = no swap). Useful for memory-constrained instances.
    mode         = optional(string, "single") # Cluster topology: "single" (default) or "1-master" (1 master + N-1 workers)
    cluster_port = optional(number)           # Intra-cluster port (creates self-referencing SG rule; required for 1-master mode)

    # EKS-specific fields (when type = "eks")
    version      = optional(string)             # Kubernetes version (e.g., "1.34")
    support_type = optional(string, "STANDARD") # EKS support type: "STANDARD" or "EXTENDED" (default: "STANDARD")
    vpc_id       = optional(string)             # VPC ID (optional - will create VPC if omitted)
    subnet_ids   = optional(list(string))       # Subnet IDs (optional - will create subnets if omitted)
    node_groups = optional(map(object({         # EKS managed node groups
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
    addons                  = optional(list(string), []) # EKS addons (e.g., coredns, vpc-cni)
    endpoint_public_access  = optional(bool, false)      # Cluster endpoint public access
    endpoint_private_access = optional(bool, true)       # Cluster endpoint private access
    cluster_admins          = optional(list(string), []) # IAM users/roles for cluster admin access

    # ECS-specific fields (when type = "ecs")
    container_insights = optional(bool, true) # Enable CloudWatch Container Insights

    # Common fields (all types)
    description = optional(string, "")      # Description for documentation (max 128 chars, added to AWS tags)
    tags        = optional(map(string), {}) # Additional tags to apply to resources of this class

    # Application deployments (dependency inversion - declares applications needed by this class)
    applications = optional(list(object({
      # Script-based deployments (SSM/user-data)
      script = optional(string)          # Script filename in applications/scripts/ (required if type=ssm|user-data)
      params = optional(map(string), {}) # Parameters passed as environment variables to the script
      type   = optional(string, "ssm")   # Deployment type: "ssm" (default), "user-data", "helm", "ansible", or "shell"

      # Ansible-specific fields (required if type=ansible)
      playbook      = optional(string) # Playbook directory name in applications/ansible/ (e.g., "redis")
      playbook_file = optional(string) # Playbook filename within directory (default: "playbook.yml")

      # Helm-specific fields (required if type=helm)
      chart        = optional(string)            # Chart name (e.g., "ingress-nginx")
      repository   = optional(string)            # Helm repo URL (e.g., "https://kubernetes.github.io/ingress-nginx")
      version      = optional(string)            # Chart version (e.g., "4.11.3")
      namespace    = optional(string, "default") # Kubernetes namespace (auto-created by compute module)
      release_name = optional(string)            # Helm release name (defaults to chart name if omitted)
      values       = optional(string)            # Inline YAML values (multiline string)
      wait         = optional(bool, true)        # Wait for resources to be ready
      timeout      = optional(number, 300)       # Timeout in seconds
    })), [])
  }))

  default = {}

  # Validation: class type must be valid
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      contains(["ec2", "eks", "ecs", "localhost"], class_config.type)
    ])
    error_message = "Class type must be one of: ec2, eks, ecs, localhost"
  }

  # Validation: EC2 classes must have ami_ssm_parameter or ami_filter
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "ec2" || class_config.ami_ssm_parameter != null || class_config.ami_filter != null
    ])
    error_message = "EC2 classes (type = 'ec2') must specify ami_ssm_parameter or ami_filter"
  }

  # Validation: EKS classes must have version and node_groups
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "eks" || (class_config.version != null && class_config.node_groups != null)
    ])
    error_message = "EKS classes (type = 'eks') must specify version and node_groups"
  }

  # Validation: per-class instance types (EC2 only)
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "ec2" ||
      can(regex("^[a-z]+[0-9]+[a-z]*\\.[a-z0-9]+$", class_config.instance_type))
    ])
    error_message = "EC2 class instance_type must be valid AWS instance type format (e.g., m6a.2xlarge, t3.small)"
  }

  # Validation: per-class volume sizes (EC2 only)
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "ec2" ||
      (class_config.volume_size >= 8 && class_config.volume_size <= 16384)
    ])
    error_message = "EC2 class volume_size must be between 8 and 16384 GB"
  }

  # Validation: per-class count (EC2 only)
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "ec2" ||
      class_config.count >= 1 && class_config.count <= 25
    ])
    error_message = "EC2 class count must be between 1 and 25 instances per tenant"
  }

  # Validation: mode must be a known topology (EC2 only)
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "ec2" || contains(["single", "1-master"], class_config.mode)
    ])
    error_message = "EC2 class mode must be 'single' or '1-master'"
  }

  # Validation: 1-master mode requires count > 1
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      class_config.type != "ec2" || class_config.mode != "1-master" || class_config.count > 1
    ])
    error_message = "EC2 class mode '1-master' requires count > 1 (need at least one master and one worker)"
  }

  # Validation: per-class description length
  validation {
    condition = alltrue([
      for class_name, class_config in var.config :
      length(class_config.description) <= 128
    ])
    error_message = "Class description must be 128 characters or less"
  }

  # Validation: ingress protocol must be "http" or "https"
  validation {
    condition = alltrue(flatten([
      for class_name, class_config in var.config : [
        for rule in coalesce(class_config.ingress, []) :
        contains(["http", "https"], rule.protocol)
      ]
    ]))
    error_message = "Ingress rule protocol must be 'http' or 'https'"
  }
}

# Instance parameters (dependency inversion interface)
# Allows modules to define Parameter Store entries that should be created for each instance
# Compute module creates the actual aws_ssm_parameter resources
variable "instance_parameters" {
  description = "Parameter Store definitions for each instance (compute module creates resources)"
  type = list(object({
    path_template    = string # Path with {instance_id} and {username} placeholders
    description      = string # Parameter description
    default_username = string # Default username for {username} placeholder
    initial_value    = string # Initial parameter value
    type             = string # Parameter type: "String", "SecureString", "StringList"
  }))
  default = []
}

# Application requests (dependency inversion interface)
# All types of application requests - this module filters internally by type (user-data, helm)
variable "application_requests" {
  description = "All application deployment requests from applications module - filtered internally by type"
  type = list(object({
    class  = string
    type   = string
    params = optional(map(string))

    # Target selection (for SSM/Ansible - not used by compute)
    target_tag_key   = optional(string)
    target_tag_value = optional(string)

    # User-data specific fields (optional)
    script             = optional(string)
    script_source_path = optional(string)

    # Helm-specific fields (optional)
    chart        = optional(string)
    repository   = optional(string)
    version      = optional(string)
    namespace    = optional(string)
    release_name = optional(string)
    values       = optional(string)
    wait         = optional(bool)
    timeout      = optional(number)

    # SSM/Ansible-specific fields (optional - not used by this module)
    tenant               = optional(string)
    playbook             = optional(string)
    playbook_file        = optional(string)
    playbook_source_path = optional(string)
  }))
  default = []
}

# Pod Identity requests (dependency inversion interface)
# Modules emit these to request IAM roles bound to K8s service accounts via Pod Identity
variable "pod_identity_requests" {
  description = "Pod Identity association requests from upstream modules (e.g., observability)"
  type = list(object({
    name            = string
    cluster_class   = string
    namespace       = string
    service_account = string
    policy          = string # JSON-encoded IAM policy document
  }))
  default = []
}

# Load Balancer requests (dependency inversion interface)
# Modules emit these to request Terraform-managed NLBs for EKS services
# Replaces K8s-managed LoadBalancer services with Terraform-owned infrastructure
variable "lb_requests" {
  description = "NLB requests for EKS services (observability, etc.) - Terraform-managed infrastructure"
  type = list(object({
    name              = string                  # Unique LB name suffix (e.g., "loki-gateway")
    cluster_class     = string                  # EKS class name (e.g., "observability")
    port              = number                  # Listener port (e.g., 80)
    node_port         = number                  # Static NodePort on EKS nodes (e.g., 30080)
    protocol          = optional(string, "TCP") # NLB protocol
    health_check_path = optional(string)        # HTTP health check path (null = TCP health check)
    internal          = optional(bool, false)   # Internal NLB (default: internet-facing)
  }))
  default = []
}

# Built AMIs from build module (golden AMI IDs for classes with build: true)
variable "built_amis" {
  description = "Map of class name to golden AMI ID (from build module)"
  type        = map(string)
  default     = {}
}

# Standalone applications (dependency inversion interface)
# Raw standalone application definitions from services.applications
# Used by ImageBuilder to bake standalone apps (wildcard/tags/compute targeting) into golden AMIs
variable "standalone_applications" {
  description = "Standalone application definitions (services.applications) for ImageBuilder inclusion"
  type        = any
  default     = {}
}

# Patch group mappings (dependency inversion interface)
# Maps class names to their namespaced patch group names for patch management targeting
variable "patch_groups_by_class" {
  description = "Map of class names to their namespaced patch group names (provided by configuration-management module)"
  type        = map(string)
  default     = {}
}

# Domain configuration (dependency inversion from domains module)
# domain_enabled is config-derived (plan-time safe) - gates for_each on ALB resources.
# The ARN/zone values are resource outputs used only inside resource bodies, not keys.
variable "domain_enabled" {
  description = "Whether domains module is active (plan-time safe, from config)"
  type        = bool
  default     = false
}

variable "domain_zone_id" {
  description = "Route53 hosted zone ID for DNS records (empty = no domain)"
  type        = string
  default     = ""
}

variable "domain_zone_name" {
  description = "Route53 hosted zone name (e.g., dev-platform.example.com)"
  type        = string
  default     = ""
}

variable "domain_certificate_arn" {
  description = "ACM certificate ARN for HTTPS listeners (empty = no HTTPS)"
  type        = string
  default     = ""
}

variable "domain_aliases" {
  description = "DNS alias map: FQDN -> compute class name (from domains module)"
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

variable "access_instance_profile_names" {
  description = "Instance profile names from access module (keyed by module-purpose)"
  type        = map(string)
  default     = {}
}
