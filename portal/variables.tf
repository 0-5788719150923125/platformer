variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "subspace" {
  description = "Shared portal namespace inherited from the default workspace. Matches namespace when in the default workspace; diverges in named workspaces. Used to share blueprints, pages, and scorecard without duplicating them."
  type        = string
}

variable "is_default_workspace" {
  description = "True when running in the default Terraform workspace. Drives is_subspace: shared Port.io resources (blueprints, pages, scorecards) are only managed by the default workspace."
  type        = bool
  default     = true
}

variable "teams" {
  description = "Port.io teams to scope all resource permissions to"
  type        = list(string)
  default     = ["sso_port_info_sec", "sso_port_platform", "sso_port_sre", "sso_port_reader"]
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure (used to scope the page into a Port folder)"
  type        = string
  default     = "Platform"
}

variable "compute_instances" {
  description = "Compute instance inventory from compute module"
  type = map(object({
    id            = string
    private_ip    = string
    public_ip     = string
    subnet_id     = string
    ami           = string
    tenant        = string
    class         = string
    instance_type = string
  }))
  default = {}
}

variable "eks_clusters" {
  description = "EKS cluster inventory from compute module"
  type = map(object({
    id      = string
    version = string
    status  = string
  }))
  default = {}
}

variable "ecs_clusters" {
  description = "ECS cluster inventory from compute module"
  type = map(object({
    id   = string
    arn  = string
    name = string
  }))
  default = {}
}

variable "port_client_id" {
  description = "Port.io API client ID"
  type        = string
  sensitive   = true
}

variable "port_secret" {
  description = "Port.io API client secret"
  type        = string
  sensitive   = true
}

variable "port_org_id" {
  description = "Port.io organization ID"
  type        = string
}

variable "aws_profile" {
  description = "AWS profile for credentials passthrough to Docker containers"
  type        = string
}

variable "aws_sso_start_url" {
  description = "AWS SSO start URL for console auto-login (e.g., https://d-1234567890.awsapps.com/start)"
  type        = string
  default     = "https://d-1234567890.awsapps.com/start"
}

variable "patch_management_enabled" {
  description = "Indicates if any patch management is configured (class-based or wildcard)"
  type        = bool
  default     = false
}

variable "patch_management_by_class" {
  description = "Per-class patch management configuration from configuration-management module"
  type = map(object({
    patch_group        = string
    baseline           = string
    baseline_os        = string
    maintenance_window = optional(string)
  }))
  default = {}
}

variable "commands" {
  description = "Standardized operational commands from all modules for portal actions and CLI display"
  type = list(object({
    title          = string
    description    = string
    commands       = list(string)
    service        = string
    category       = string
    target_type    = string
    target         = string
    execution      = string
    action_config  = map(string)
    blueprint_type = optional(string, "compute")
  }))
  default = []
}

variable "tenant_entitlements" {
  description = "Map of tenant codes to their entitlement lists"
  type        = map(list(string))
  default     = {}
}

variable "service_urls" {
  description = "Unified service URL registry from root module (service, module, tenants, deployment, metadata)"
  type = map(object({
    url        = optional(string)
    service    = string
    module     = string
    tenants    = list(string)
    deployment = string
    metadata   = map(any)
  }))
  default = {}
}

variable "states" {
  description = "List of state fragment names loaded for this deployment"
  type        = list(string)
  default     = []
}

variable "event_bus_requests" {
  description = "Event bus webhook subscription requests from modules (dependency inversion)"
  type = list(object({
    purpose     = string
    description = string
    event_type  = string
    source      = string
  }))
  default = []
}

variable "artifact_requests" {
  description = "Artifact registry entries from modules (dependency inversion). Supports archives, docker images, helm charts, and golden images."
  type = list(object({
    name       = string
    version    = string
    type       = string
    path       = string
    source     = string
    created_at = string
    url        = optional(string)
  }))
  default = []
}

variable "storage_requests" {
  description = "Storage resource catalog entries from storage module (dependency inversion). Populated from storage.inventory output."
  type = list(object({
    purpose          = string
    storage_type     = string
    name             = string
    engine           = optional(string)
    description      = optional(string, "")
    url              = optional(string)
    resource_address = optional(string)
  }))
  default = []
}
