variable "application_requests" {
  description = "Application installation requests from compute module (dependency inversion)"
  type = list(object({
    class  = string           # Compute class name (for association naming)
    tenant = optional(string) # Tenant code (for per-tenant applications, null for class-level)
    type   = string           # Deployment type: "ssm", "user-data", "helm", or "ansible"

    # Script-based deployment fields (for ssm/user-data)
    script           = optional(string)      # Script filename (e.g., "install-postgresql.sh")
    params           = optional(map(string)) # Parameters passed as environment variables
    target_tag_key   = optional(string)      # Tag key for targeting (e.g., "Class" or "Tenant")
    target_tag_value = optional(string)      # Tag value for targeting (e.g., "database" or "alpha")

    # Ansible deployment fields (for ansible)
    playbook      = optional(string) # Playbook directory name (e.g., "redis")
    playbook_file = optional(string) # Playbook filename (default: "playbook.yml")

    # Targeting fields (for standalone applications and cluster mode)
    targeting_mode = optional(string, "compute") # "compute" | "wildcard" | "tags" | "instance"
    targets = optional(list(object({
      key    = string
      values = list(string)
    })))

    # Direct instance targeting (for mode: 1-master cluster requests)
    instance_id = optional(string) # EC2 instance ID  -  used when targeting_mode = "instance"

    # Helm deployment fields (for helm)
    chart        = optional(string) # Chart name (e.g., "ingress-nginx")
    repository   = optional(string) # Helm repo URL
    version      = optional(string) # Chart version
    namespace    = optional(string) # Kubernetes namespace (auto-created by compute module)
    release_name = optional(string) # Helm release name
    values       = optional(string) # Inline YAML values
    wait         = optional(bool)   # Wait for resources to be ready
    timeout      = optional(number) # Timeout in seconds
  }))
  default = []

  validation {
    condition = alltrue([
      for req in var.application_requests :
      contains(["ssm", "user-data", "helm", "ansible"], req.type)
    ])
    error_message = "Application type must be 'ssm', 'user-data', 'helm', or 'ansible'."
  }
}

variable "config" {
  description = "Standalone application definitions from services.applications (not tied to compute classes)"
  # Map key = application name (e.g., "crowdstrike", "monitoring-agent")
  type = map(object({
    type = string # "ssm", "user-data", "helm", or "ansible"

    # Script-based deployment (ssm/user-data)
    script = optional(string)          # Script filename in applications/scripts/ directory
    params = optional(map(string), {}) # Environment variables for script execution

    # Ansible deployment
    playbook      = optional(string)                 # Playbook directory name in applications/ansible/ or <module>/ansible/
    playbook_file = optional(string, "playbook.yml") # Playbook filename within playbook directory

    # Helm deployment
    chart        = optional(string)      # Chart name (e.g., "ingress-nginx")
    repository   = optional(string)      # Helm repository URL
    version      = optional(string)      # Chart version
    namespace    = optional(string)      # Kubernetes namespace (auto-created if doesn't exist)
    release_name = optional(string)      # Helm release name (defaults to chart name)
    values       = optional(string)      # Inline YAML values for Helm chart
    wait         = optional(bool, true)  # Wait for Helm resources to be ready
    timeout      = optional(number, 300) # Timeout in seconds for Helm operations

    # Targeting configuration (for SSM associations)
    targeting = optional(object({
      mode = optional(string, "wildcard") # "wildcard" | "tags" - wildcard targets ALL SSM instances
      tags = optional(map(list(string)))  # Tag-based targeting: {Class = ["web", "db"]}
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for app_name, app_config in var.config :
      contains(["ssm", "user-data", "helm", "ansible"], app_config.type)
    ])
    error_message = "Standalone application type must be 'ssm', 'user-data', 'helm', or 'ansible'."
  }
}
