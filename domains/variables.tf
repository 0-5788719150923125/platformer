variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "config" {
  description = "Domains service configuration from state fragments (services.domains)"
  type = object({
    zone    = string                      # Route53 hosted zone name (e.g., "dev-platform.example.com")
    aliases = optional(map(string), {})   # Additional DNS records: FQDN -> compute class name (e.g., "arc.src.eco" -> "praxis-arc")
  })
}
