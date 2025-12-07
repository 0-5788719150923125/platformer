variable "algorithm" {
  description = "Namespace generation algorithm: 'pet' or 'pokeform'"
  type        = string
  default     = "pokeform"

  validation {
    condition     = contains(["pet", "pokeform"], var.algorithm)
    error_message = "Algorithm must be either 'pet' or 'pokeform'"
  }
}

variable "seed" {
  description = "Seed value for deterministic name generation (pokeform only)"
  type        = string
  default     = ""
}

variable "length" {
  description = "Length parameter for random_pet (pet only)"
  type        = number
  default     = 2
}
