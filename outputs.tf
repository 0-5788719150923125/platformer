
# Command Registry aggregation
locals {
  # Concatenate commands from all modules
  all_commands = concat(
    local.configuration_management_enabled ? module.configuration_management[0].commands : [],
    local.compute_enabled ? module.compute[0].commands : [],
    local.compute_enabled && length(module.build) > 0 ? module.build[0].commands : [],
    local.archbot_enabled ? module.archbot[0].commands : [],
    local.storage_enabled ? module.storage[0].commands : [],
  )

  # Deduplicate: group by category, keep first instance only
  commands_by_category = { for cmd in local.all_commands : cmd.category => cmd... }
  cli_commands = {
    for cat, cmds in local.commands_by_category : cat => {
      title       = cmds[0].title
      description = cmds[0].description
      examples    = cmds[0].commands
      count       = length(cmds)
    }
  }

  # Unified Service URL Registry
  # Aggregates all service URLs across modules with consistent metadata
  # Format: { unique_key => { url, service, module, tenants, deployment, metadata } }
  service_urls = merge(
    # ArchOrchestrator ALB URLs (deployment-wide, multi-tenant)
    local.archorchestrator_enabled ? {
      for deploy_name, alb_url in module.archorchestrator[0].alb_urls :
      "archorchestrator-${deploy_name}" => {
        url        = alb_url
        service    = "ArchOrchestrator"
        module     = "archorchestrator"
        tenants    = lookup(module.tenants.tenants_by_class, deploy_name, [])
        deployment = deploy_name
        metadata = {
          type        = "alb"
          protocol    = "http"
          description = "IO Cloud services (SaaSApp, CoreApps, Router)"
        }
      }
    } : {},

    # Instance URLs (per-instance, single tenant)
    # Keys built from config-derived service_instance_keys (plan-time safe) so portal
    # can use this map in for_each without "unknown keys" errors.
    # Only includes instances whose class has ingress rules - bare instances (e.g. rocky-linux)
    # with no web service are excluded from the portal widget.
    # HTTPS classes get https://{class}.{zone} URLs; HTTP classes get http://{public_dns}:{port}
    local.compute_enabled ? {
      for instance_key in module.compute[0].service_instance_keys :
      "ec2-${instance_key}" => {
        url = (
          # HTTPS instance: use per-instance ALB FQDN
          contains(keys(module.compute[0].alb_dns_names), instance_key)
          ? "https://${module.compute[0].alb_dns_names[instance_key]}"
          # HTTP instance with domain: use per-instance DNS FQDN
          : contains(keys(module.compute[0].http_dns_names), instance_key)
          ? "http://${module.compute[0].http_dns_names[instance_key]}:${module.compute[0].instances[instance_key].ingress_ports[0]}"
          # HTTP class without domain: use public DNS + port
          : (
            module.compute[0].instances[instance_key].public_dns != "" &&
            length(module.compute[0].instances[instance_key].ingress_ports) > 0
            ? "http://${module.compute[0].instances[instance_key].public_dns}:${module.compute[0].instances[instance_key].ingress_ports[0]}"
            : null
          )
        )
        service    = module.compute[0].instances[instance_key].class
        module     = "compute"
        tenants    = [module.compute[0].instances[instance_key].tenant]
        deployment = "${module.compute[0].instances[instance_key].class}-${module.compute[0].instances[instance_key].instance_idx}"
        metadata = {
          type          = "ec2"
          protocol      = contains(keys(module.compute[0].alb_dns_names), instance_key) ? "https" : "http"
          instance_type = module.compute[0].instances[instance_key].instance_type
          ami           = module.compute[0].instances[instance_key].ami
          public_ip     = module.compute[0].instances[instance_key].public_ip
          all_ports     = jsonencode(module.compute[0].instances[instance_key].ingress_ports)
        }
      }
    } : {},

    # Observability URLs (Terraform-managed NLBs)
    local.observability_enabled && local.compute_enabled ? merge(
      contains(keys(module.compute[0].lb_dns_names), "observability-loki-gateway") ? {
        "observability-loki-gateway" = {
          url        = "http://${module.compute[0].lb_dns_names["observability-loki-gateway"]}"
          service    = "Loki"
          module     = "observability"
          tenants    = ["platform"]
          deployment = "observability"
          metadata = {
            type        = "nlb"
            protocol    = "http"
            description = "Loki log aggregation gateway (push endpoint)"
          }
        }
      } : {},
      contains(keys(module.compute[0].lb_dns_names), "observability-grafana") ? {
        "observability-grafana" = {
          url        = "http://${module.compute[0].lb_dns_names["observability-grafana"]}"
          service    = "Grafana"
          module     = "observability"
          tenants    = ["platform"]
          deployment = "observability"
          metadata = {
            type        = "nlb"
            protocol    = "http"
            description = "Grafana observability dashboard (Loki datasource pre-configured)"
          }
        }
      } : {}
    ) : {},

    # archbot webhook URLs (one per atlassian bot)
    local.archbot_enabled ? {
      for entry in module.archbot[0].service_url_entries :
      entry.deployment => entry
    } : {},

    # Archshare URLs (per deployment-tenant, queried from Kubernetes)
    local.archshare_enabled && local.compute_enabled ? {
      for key, dc in module.archshare[0].eks_deployment_tenants :
      "archshare-${key}" => {
        url = (
          module.archshare[0].frontend_service_urls[key] != null &&
          module.archshare[0].frontend_service_urls[key] != ""
          ? "http://${module.archshare[0].frontend_service_urls[key]}"
          : null
        )
        service    = "Archshare"
        module     = "archshare"
        tenants    = [dc.tenant]
        deployment = dc.deployment
        metadata = {
          type        = "eks-service"
          protocol    = "http"
          description = "Medical imaging platform frontend"
        }
      }
    } : {}
  )

  # Pass service URLs to portal. EC2 entries are pre-filtered at the source
  # (service_instance_keys excludes classes with no ingress_ports).
  # Remaining null URLs (e.g. lazy-eval Archshare) are handled gracefully by portal.
  service_urls_filtered = local.service_urls
}

# Unified Service URLs (key-to-URL mapping for all services)
output "service_urls" {
  description = "Service URL registry  -  key-to-URL mapping (null entries excluded)"
  value = {
    for key, entry in local.service_urls_filtered :
    key => entry.url
    if entry.url != null
  }
}

# Command Registry  -  category-to-commands mapping for deployers
output "commands" {
  description = "Single operational commands by category"
  value = {
    for cat, cmd in local.cli_commands :
    cat => cmd.examples[0]
    if length(cmd.examples) == 1
  }
}

output "workflows" {
  description = "Multi-step operational workflows by category"
  value = {
    for cat, cmd in local.cli_commands :
    cat => cmd.examples
    if length(cmd.examples) > 1
  }
}

output "enabled_services" {
  description = "List of enabled services in this deployment (includes auto-enabled and explicitly configured)"
  value       = [for service, enabled in module.resolver.enabled : service if enabled]
}

output "deployment_id" {
  description = "Unique deployment identifier (namespace) for this account/region deployment"
  value       = local.subspace
}

output "access_summary" {
  description = "Access control summary - rule counts by module"
  value       = module.access.access_summary
}