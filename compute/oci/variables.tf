# Adapter contract (see compute/adapters.tf): config + context in, instances out.

variable "config" {
  description = "OCI instances from generic instance classes, keyed <tenant>-<class>-<idx>"
  type = map(object({
    tenant   = string
    class    = string
    index    = number
    adopt_id = optional(string)
    settings = object({
      shape                   = string
      ocpus                   = optional(number)
      memory_in_gbs           = optional(number)
      image_id                = string
      subnet_id               = string
      availability_domain     = string
      compartment_id          = optional(string)
      assign_public_ip        = optional(bool, true)
      ssh_authorized_keys     = optional(string)
      boot_volume_size_in_gbs = optional(number)
      ingress = optional(list(object({
        protocol    = string
        ports       = string
        source      = optional(string, "0.0.0.0/0")
        description = optional(string)
      })), [])
    })
  }))
}

variable "context" {
  description = "Values shared with every adapter"
  type = object({
    namespace = string
  })
}
