variable "application_requests" {
  description = "Application installation requests from compute module (dependency inversion)"
  type = list(object({
    class  = string           # Compute class name (for association naming)
    tenant = optional(string) # Tenant code (for per-tenant applications, null for class-level)
    type   = string           # Deployment type: "ssm", "compose", "user-data", "helm", or "ansible"

    # Script-based deployment fields (for ssm/compose/user-data)
    script           = optional(string)      # Script filename (e.g., "install-postgresql.sh")
    params           = optional(map(string)) # Parameters passed as environment variables
    environment      = optional(map(string)) # Application environment (ssm: $APP_ENV_FILE, compose: the project's .env)
    teardown         = optional(bool)        # Run the script with APP_ACTION=down when the request is removed
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
    instance_id = optional(string) # EC2 instance ID - used when targeting_mode = "instance"

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
      contains(["ssm", "compose", "user-data", "helm", "ansible"], req.type)
    ])
    error_message = "Application type must be 'ssm', 'compose', 'user-data', 'helm', or 'ansible'."
  }
}

variable "config" {
  description = "Standalone application definitions from services.applications (not tied to compute classes)"
  # Map key = application name (e.g., "crowdstrike", "src")
  type = map(object({
    type = string # "ssm", "compose", "user-data", "helm", or "ansible"

    # Script-based deployment (ssm/user-data)
    script = optional(string)          # Script filename in applications/scripts/ directory
    params = optional(map(string), {}) # Environment variables for script execution

    # Application environment (ssm/compose). ssm: written to $APP_ENV_FILE for the
    # script; compose: the project's .env. List values in the fragment are
    # joined with commas before they get here (root main.tf).
    environment = optional(map(string), {})

    # Compose stack (compose): a git repository checked out and run by
    # applications/scripts/compose-stack.sh
    repository = optional(string)           # Source repository: git URL (compose) or Helm repository URL (helm)
    ref        = optional(string)           # Branch, tag or commit (default: the remote's default branch)
    path       = optional(string, ".")      # Compose project directory inside the repository
    directory  = optional(string)           # Checkout location (default: /opt/stacks/<name>)
    profiles   = optional(list(string), []) # Compose profiles to run (becomes COMPOSE_PROFILES)
    ports      = optional(list(string), []) # Host firewall openings, e.g. "443/tcp", "51000-51999/udp"

    # Ansible deployment
    playbook      = optional(string)                 # Playbook directory name in applications/ansible/ or <module>/ansible/
    playbook_file = optional(string, "playbook.yml") # Playbook filename within playbook directory

    # Helm deployment
    chart        = optional(string)      # Chart name (e.g., "ingress-nginx")
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

    # Per-host deployments (ssm/compose), instead of targeting: one deployment per
    # entry, pinned to an instance (EC2 or hybrid mi-), with environment overrides
    hosts = optional(map(object({
      instance_id = string                    # Instance to deploy to
      environment = optional(map(string), {}) # Replaces the app's values for this host
    })), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for app_name, app_config in var.config :
      contains(["ssm", "compose", "user-data", "helm", "ansible"], app_config.type)
    ])
    error_message = "Standalone application type must be 'ssm', 'compose', 'user-data', 'helm', or 'ansible'."
  }

  validation {
    condition = alltrue([
      for app_name, app_config in var.config :
      app_config.type != "compose" || (
        can(regex("^[a-z0-9][a-z0-9_-]*$", app_name)) && app_config.repository != null && app_config.repository != ""
      )
    ])
    error_message = "compose applications need a repository, and a name of lowercase letters, digits, - and _ (it names the compose project and its systemd unit)."
  }

  validation {
    condition = alltrue(flatten([
      for app_name, app_config in var.config : [
        for port in app_config.ports : can(regex("^[0-9]+(-[0-9]+)?/(tcp|udp)$", port))
      ]
    ]))
    error_message = "ports entries look like \"443/tcp\" or \"51000-51999/udp\"."
  }

  validation {
    condition = alltrue([
      for app_name, app_config in var.config :
      length(app_config.hosts) == 0 || contains(["ssm", "compose"], app_config.type)
    ])
    error_message = "hosts is supported for ssm and compose applications."
  }
}
