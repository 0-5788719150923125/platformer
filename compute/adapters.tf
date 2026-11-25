# Cloud Adapters
#
# Generic instance classes (type = "instance") name the cloud they live in. Each
# cloud's implementation is an adapter module in compute/<cloud>/, and every
# adapter keeps the same contract:
#
#   in:  config  - this cloud's instances, keyed <tenant>-<class>-<idx> like EC2
#        context - values every adapter may need (namespace, ...)
#   out: instances - map of instance key => { id, display_name, public_ip, ... }
#
# This file is generic: it routes instances to clouds and merges results, and
# never names a cloud. Adapters are wired in per workspace by scripts/providers.sh,
# which writes adapter_<cloud>.tf (the module call) and adapters_override.tf
# (replacing `adapters` below). The committed default wires no adapters, so a
# workspace that doesn't use a cloud never loads that cloud's provider.

locals {
  adapters = {}
}

locals {
  instance_classes = {
    for class_name, class_config in var.config : class_name => class_config
    if class_config.type == "instance" && length(lookup(var.tenants_by_class, class_name, [])) > 0
  }

  # tenant x class x count, keyed like EC2 instances
  generic_instances = merge([
    for tenant in local.effective_tenants : merge([
      for class_name, class_config in local.instance_classes : {
        for idx in range(class_config.count) : "${tenant}-${class_name}-${idx}" => {
          tenant      = tenant
          class       = class_name
          index       = idx
          cloud       = class_config.cloud
          adopt_id    = try(class_config.adopt[idx], null)
          description = class_config.description
          tags        = class_config.tags
          settings    = class_config[class_config.cloud]
        }
      }
      if contains(lookup(var.tenants_by_class, class_name, []), tenant)
    ]...)
  ]...)

  # Instances grouped by the cloud whose adapter runs them
  adapter_config = {
    for cloud in distinct([for key, instance in local.generic_instances : instance.cloud]) : cloud => {
      for key, instance in local.generic_instances : key => instance if instance.cloud == cloud
    }
  }

  adapter_context = {
    namespace = var.namespace
  }

  # Existing resources to import instead of create (see the import blocks in providers/<cloud>.tf)
  adoptions = {
    for cloud, instances in local.adapter_config : cloud => {
      for key, instance in instances : key => instance.adopt_id if instance.adopt_id != null
    }
  }

  # Adoption maps list indexes to instances, so it needs exactly one tenant: with
  # several the mapping is ambiguous, and with none nothing would be imported
  # (e.g. a tenant missing from tenants/tenants.yaml) without anyone noticing.
  ambiguous_adoptions = [
    for class_name, class_config in var.config : class_name
    if class_config.type == "instance" && length(class_config.adopt) > 0 && length(lookup(var.tenants_by_class, class_name, [])) != 1
  ]
}
