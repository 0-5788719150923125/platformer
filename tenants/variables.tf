# Tenants Module Variables

# Tenant configuration from matrix.tenants
# Each tenant declares which services (and optionally classes) they are entitled to
# Supports dot-notation: "compute" = all classes, "compute.windows-server" = specific class
# Map key = tenant code (e.g., "bravo", "alpha", "november")
variable "config" {
  description = "Tenant entitlement declarations from matrix.tenants config"
  type = map(object({
    entitlements = optional(list(string), []) # Service/class entitlements using dot-notation
  }))
  default = {}
}

# Class names defined in each service (for resolving bare entitlements to all classes)
# e.g., { compute = ["windows-server", "rocky-linux"] }
# A bare "compute" entitlement resolves to all classes listed here
variable "service_class_names" {
  description = "Map of service name to class names defined in that service"
  type        = map(list(string))
  default     = {}
}

# Future: Add ServiceNow integration configuration
# variable "config" {
#   description = "Tenants module configuration"
#   type = object({
#     source       = optional(string, "hardcoded")  # "hardcoded" or "servicenow"
#     api_endpoint = optional(string)               # ServiceNow API endpoint
#     filters      = optional(map(string), {})      # API filters
#   })
#   default = {}
# }
