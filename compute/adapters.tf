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
  # AWS instances run on the AWS adapter's EC2 path (see main.tf), not through here
  instance_classes = {
    for class_name, class_config in var.config : class_name => class_config
    if class_config.type == "instance" && class_config.cloud != "aws" && length(lookup(var.tenants_by_class, class_name, [])) > 0
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
    if class_config.type == "instance" && class_config.cloud != "aws" && length(class_config.adopt) > 0 && length(lookup(var.tenants_by_class, class_name, [])) != 1
  ]
}

# The AWS adapter's outputs, one local each. These are the values when the
# workspace doesn't use AWS; aws/wiring_override.tf.tmpl (linked in as
# adapter_aws_override.tf by scripts/providers.sh) points each at module.aws.
# One local per output keeps dependencies per output: referencing the module as
# a whole would tie every output to every other and close request round-trips
# (e.g. archivist -> storage -> archivist) into cycles.
locals {
  aws_wired = false

  aws_output_instances                    = {}
  aws_output_instance_keys                = []
  aws_output_service_instance_keys        = []
  aws_output_config                       = {}
  aws_output_instances_by_tenant          = {}
  aws_output_instances_by_class           = {}
  aws_output_eks_clusters                 = {}
  aws_output_eks_cluster_security_groups  = {}
  aws_output_eks_node_groups              = {}
  aws_output_eks_test_commands            = {}
  aws_output_application_requests         = []
  aws_output_cluster_application_requests = []
  aws_output_instance_role_arn            = ""
  aws_output_instance_role_name           = ""
  aws_output_eks_node_role_name           = 0
  aws_output_alb_dns_names                = {}
  aws_output_http_dns_names               = {}
  aws_output_alias_fqdn_by_class          = {}
  aws_output_lb_dns_names                 = {}
  aws_output_helm_releases                = {}
  aws_output_commands                     = []
  aws_output_kubeconfig_ready             = {}
  aws_output_ecs_clusters                 = {}
  aws_output_volume_requests              = []
  aws_output_access_requests              = []
  aws_output_access_security_groups       = []
  aws_output_ecs_test_commands            = {}
}
