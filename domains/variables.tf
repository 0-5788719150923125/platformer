variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "config" {
  description = "Domains service configuration from state fragments (services.domains)"
  type = object({
    zone = string # Route53 hosted zone name (e.g., "dev-platform.example.com")
  })
}
