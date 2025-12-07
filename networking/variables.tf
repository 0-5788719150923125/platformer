# Core Variables (passed from root)
variable "namespace" {
  description = "Deployment namespace for resource isolation"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID (used for deterministic CIDR allocation)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must be a 12-digit number"
  }
}

variable "network_name" {
  description = "Name of this network (for tagging and identification in multi-VPC scenarios)"
  type        = string
}

# Network Configuration
variable "config" {
  description = "Network service configuration"
  type = object({
    # CIDR allocation strategy
    base_cidr         = optional(string, "10.0.0.0/8")
    allocation_method = optional(string, "default") # default, deterministic, or explicit
    explicit_cidr     = optional(string)            # Used when allocation_method = "explicit"

    # Availability zone configuration
    az_count     = optional(number, 3)
    az_selection = optional(string, "alphabetical") # alphabetical, all, or explicit
    explicit_azs = optional(list(string), [])       # Used when az_selection = "explicit"
    max_azs      = optional(number, 3)              # Maximum AZs to use (for cost control)

    # Network topology per VPC
    # Each tier defines a subnet class (private, public, intra)
    subnet_topology = optional(map(object({
      cidr_newbits            = number                # Additional bits for subnet mask (/16 VPC → /24 = 8 bits)
      offset                  = number                # Starting offset in CIDR space
      nat_gateway             = optional(bool, false) # Create NAT gateway for this tier
      internet_gateway        = optional(bool, false) # Create Internet gateway for this tier
      map_public_ip_on_launch = optional(bool, false) # Auto-assign public IPs
      isolated                = optional(bool, false) # No internet routing
      tags                    = optional(map(string), {})
      })), {
      private = {
        cidr_newbits            = 8 # /16 VPC → /24 subnets (256 hosts)
        offset                  = 0 # Start at 10.X.0.0/24
        nat_gateway             = true
        map_public_ip_on_launch = false
        tags                    = { Tier = "Private" }
      }
      public = {
        cidr_newbits            = 10  # /16 VPC → /26 subnets (64 hosts)
        offset                  = 100 # Start at 10.X.25.0/26 (after private range)
        internet_gateway        = true
        map_public_ip_on_launch = true
        tags                    = { Tier = "Public" }
      }
      intra = {
        cidr_newbits = 4 # /16 VPC → /20 subnets (4096 hosts)
        offset       = 8 # Start at 10.X.128.0/20 (upper half of /16)
        isolated     = true
        tags         = { Tier = "Intra" }
      }
    })

    # Connectivity model
    connectivity = optional(object({
      mode = optional(string, "isolated") # isolated, privatelink, or transit-gateway
    }), { mode = "isolated" })

    # VPC endpoints for AWS services (PrivateLink)
    vpc_endpoints = optional(list(object({
      service = string # s3, ec2, ecr.api, ecr.dkr, logs, etc.
      type    = string # gateway or interface
    })), [])

    # Enable VPC features
    enable_dns_hostnames = optional(bool, true)
    enable_dns_support   = optional(bool, true)
    enable_nat_gateway   = optional(bool, true) # Global NAT gateway toggle

    # Tags
    tags = optional(map(string), {})
  })

  # Validation: allocation_method must be valid
  validation {
    condition     = contains(["default", "deterministic", "explicit"], var.config.allocation_method)
    error_message = "allocation_method must be 'default', 'deterministic', or 'explicit'"
  }

  # Validation: explicit_cidr required when allocation_method = "explicit"
  validation {
    condition     = var.config.allocation_method != "explicit" || var.config.explicit_cidr != null
    error_message = "explicit_cidr must be provided when allocation_method = 'explicit'"
  }

  # Validation: az_selection must be valid
  validation {
    condition     = contains(["alphabetical", "all", "explicit"], var.config.az_selection)
    error_message = "az_selection must be 'alphabetical', 'all', or 'explicit'"
  }

  # Validation: explicit_azs required when az_selection = "explicit"
  validation {
    condition     = var.config.az_selection != "explicit" || length(var.config.explicit_azs) > 0
    error_message = "explicit_azs must be provided when az_selection = 'explicit'"
  }

  # Validation: az_count reasonable range
  validation {
    condition     = var.config.az_count >= 1 && var.config.az_count <= 6
    error_message = "az_count must be between 1 and 6"
  }

  # Validation: base_cidr is valid CIDR
  validation {
    condition     = can(cidrhost(var.config.base_cidr, 0))
    error_message = "base_cidr must be a valid CIDR block"
  }

  # Validation: explicit_cidr is valid CIDR (if provided)
  validation {
    condition     = var.config.explicit_cidr == null || can(cidrhost(var.config.explicit_cidr, 0))
    error_message = "explicit_cidr must be a valid CIDR block"
  }

  # Validation: subnet topology has valid cidr_newbits
  validation {
    condition = alltrue([
      for tier, tier_config in var.config.subnet_topology :
      tier_config.cidr_newbits >= 1 && tier_config.cidr_newbits <= 16
    ])
    error_message = "subnet_topology cidr_newbits must be between 1 and 16"
  }

  # Validation: subnet topology offsets are non-negative
  validation {
    condition = alltrue([
      for tier, tier_config in var.config.subnet_topology :
      tier_config.offset >= 0
    ])
    error_message = "subnet_topology offsets must be non-negative"
  }

  # Validation: connectivity mode is valid
  validation {
    condition     = contains(["isolated", "privatelink", "transit-gateway"], var.config.connectivity.mode)
    error_message = "connectivity mode must be 'isolated', 'privatelink', or 'transit-gateway'"
  }

  # Validation: VPC endpoint types are valid
  validation {
    condition = alltrue([
      for endpoint in var.config.vpc_endpoints :
      contains(["gateway", "interface"], endpoint.type)
    ])
    error_message = "VPC endpoint type must be 'gateway' or 'interface'"
  }
}
