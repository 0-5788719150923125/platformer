# ============================================================================
# Subspace gate
# When running in a non-default workspace, subspace != namespace. Resources that
# are shared org-wide in Port.io (blueprints, pages, scorecard, permissions,
# doc/commit entities) are owned by the default workspace and must not be
# recreated here. Workspace-specific data (compute entities, service URLs,
# state fragments, artifacts, event bus webhooks) is always created.
# ============================================================================

locals {
  is_subspace = !var.is_default_workspace

  # Blueprint identifiers as plain strings so all files can reference them
  # without depending on the count-gated blueprint resources directly.
  bp_artifact           = "artifact-${var.subspace}"
  bp_compute_instance   = "computeInstance-${var.subspace}"
  bp_documentation      = "documentation-${var.subspace}"
  bp_event_bus          = "eventBus-${var.subspace}"
  bp_git_commit         = "gitCommit-${var.subspace}"
  bp_service_url        = "serviceUrl-${var.subspace}"
  bp_state_fragment     = "stateFragment-${var.subspace}"
  bp_storage            = "storage-${var.subspace}"
  bp_tenant_entitlement = "tenantEntitlement-${var.subspace}"
}

# ============================================================================
# Preflight Checks - Validate dependencies before creating resources
# ============================================================================

locals {
  required_tools = {
    docker = {
      type     = "discrete"
      commands = ["docker"]
    }
    docker-compose = {
      type     = "any"
      commands = ["docker compose", "docker-compose"]
    }
  }
}

module "preflight" {
  source = "git::https://github.com/acme-sandbox/platformer//platformer/preflight?ref=32f494a44c07828cecb58311e55b1095d0804a55"

  # Validation happens automatically within the preflight module
  required_tools = local.required_tools
}

# ============================================================================
# Port.io Resources
# ============================================================================

# Blueprint for platformer compute instances
resource "port_blueprint" "platformer_compute_instance" {
  count = local.is_subspace ? 0 : 1

  identifier = "computeInstance-${var.namespace}"
  title      = "Compute Instance"
  icon       = "Server"

  ownership = {
    type = "Direct"
  }

  properties = {
    string_props = {
      instanceId = {
        title       = "Instance ID"
        description = "AWS instance ID (e.g., i-1234567890abcdef0)"
      }
      tenant = {
        title       = "Tenant"
        description = "Tenant or organization owning this instance"
      }
      class = {
        title       = "Class"
        description = "Instance class definition from platformer state"
      }
      instanceType = {
        title       = "Instance Type"
        description = "EC2 instance type or EKS version"
      }
      privateIp = {
        title       = "Private IP"
        description = "Private IP address (EC2 only)"
      }
      publicIp = {
        title       = "Public IP"
        description = "Public IP address (EC2 only)"
      }
      subnetId = {
        title       = "Subnet ID"
        description = "Subnet ID (EC2 only)"
      }
      ami = {
        title       = "AMI"
        description = "Amazon Machine Image ID (EC2 only)"
      }
      region = {
        title       = "Region"
        description = "AWS region where the instance is deployed"
        required    = true
      }
      namespace = {
        title       = "Namespace"
        description = "Platformer namespace for resource isolation"
        required    = true
      }
      workspace = {
        title       = "Workspace"
        description = "Terraform workspace that produced this entry"
        required    = true
      }
      type = {
        title       = "Type"
        description = "Instance type: EC2, EKS, or ECS"
        required    = true
        enum        = ["ec2", "eks", "ecs"]
        enum_colors = {
          ec2 = "blue"
          eks = "turquoise"
          ecs = "green"
        }
      }
      status = {
        title       = "Status"
        description = "Current status of the instance"
        required    = true
      }
      awsUrl = {
        title       = "AWS Console"
        description = "Direct link to AWS Console for this resource"
        format      = "url"
      }
      ssmUrl = {
        title       = "Systems Manager"
        description = "Direct link to AWS Systems Manager for this instance (EC2 only)"
        format      = "url"
      }
      sessionManagerUrl = {
        title       = "Session Manager"
        description = "Direct link to start an SSM Session Manager session (EC2 only)"
        format      = "url"
      }
      awsProfile = {
        title       = "AWS Profile"
        description = "AWS profile used for this deployment"
      }
      patchGroup = {
        title       = "Patch Group"
        description = "SSM Patch Group name assigned to this instance's class"
      }
      patchBaseline = {
        title       = "Patch Baseline"
        description = "SSM Patch Baseline covering this instance's class"
      }
      patchBaselineOs = {
        title       = "Patch Baseline OS"
        description = "Operating system targeted by the patch baseline"
      }
      patchMaintenanceWindow = {
        title       = "Patch Maintenance Window"
        description = "SSM Maintenance Window scheduling patches for this instance's class"
      }
      patchReadinessLevel = {
        title       = "Patch Readiness Level"
        description = "Patch management configuration maturity: Gold (maintenance window), Silver (baseline), Bronze (patch group), Basic (none)"
        enum        = ["Gold", "Silver", "Bronze", "Basic"]
        enum_colors = {
          Gold   = "green"
          Silver = "blue"
          Bronze = "orange"
          Basic  = "red"
        }
      }
      patchComplianceStatus = {
        title       = "Patch Compliance Status"
        description = "Runtime patch compliance status from SSM (updated by Lambda reporter)"
        enum        = ["COMPLIANT", "NON_COMPLIANT", "UNKNOWN"]
        enum_colors = {
          COMPLIANT     = "green"
          NON_COMPLIANT = "red"
          UNKNOWN       = "lightGray"
        }
      }
      patchLastScanTime = {
        title       = "Last Patch Scan"
        description = "Timestamp of last SSM patch compliance scan"
      }
    }
    number_props = {
      patchInstalledCount = {
        title       = "Patches Installed"
        description = "Number of patches installed on this instance"
      }
      patchMissingCount = {
        title       = "Patches Missing"
        description = "Number of patches missing on this instance"
      }
    }
  }
}

locals {
  # SSO console URL prefix — wraps raw AWS console URLs so users land on the
  # SSO role-picker for the correct account instead of a generic login page.
  sso_prefix = "${var.aws_sso_start_url}/#/console?account_id=${data.aws_caller_identity.current.account_id}&destination="

  # Flatten EC2 instances for entity creation
  ec2_entities = {
    for key, instance in var.compute_instances : key => {
      identifier = "${key}-${var.namespace}"
      title      = key
      blueprint  = local.bp_compute_instance
      properties = {
        instanceId             = instance.id
        tenant                 = instance.tenant
        class                  = instance.class
        instanceType           = instance.instance_type
        privateIp              = instance.private_ip
        publicIp               = instance.public_ip != "" ? instance.public_ip : null
        subnetId               = instance.subnet_id
        ami                    = instance.ami
        region                 = data.aws_region.current.id
        namespace              = var.subspace
        workspace              = var.namespace
        type                   = "ec2"
        status                 = "active"
        awsUrl                 = "${local.sso_prefix}${urlencode("https://${data.aws_region.current.id}.console.aws.amazon.com/ec2/home?region=${data.aws_region.current.id}#InstanceDetails:instanceId=${instance.id}")}"
        ssmUrl                 = "${local.sso_prefix}${urlencode("https://${data.aws_region.current.id}.console.aws.amazon.com/systems-manager/explore-nodes/${instance.id}?region=${data.aws_region.current.id}")}"
        sessionManagerUrl      = "${local.sso_prefix}${urlencode("https://${data.aws_region.current.id}.console.aws.amazon.com/systems-manager/session-manager/${instance.id}?region=${data.aws_region.current.id}#:")}"
        awsProfile             = var.aws_profile
        patchGroup             = try(var.patch_management_by_class[instance.class].patch_group, null)
        patchBaseline          = try(var.patch_management_by_class[instance.class].baseline, null)
        patchBaselineOs        = try(var.patch_management_by_class[instance.class].baseline_os, null)
        patchMaintenanceWindow = try(var.patch_management_by_class[instance.class].maintenance_window, null)
        patchReadinessLevel = (
          try(var.patch_management_by_class[instance.class].maintenance_window, null) != null ? "Gold" :
          try(var.patch_management_by_class[instance.class].baseline, null) != null ? "Silver" :
          try(var.patch_management_by_class[instance.class].patch_group, null) != null ? "Bronze" :
          "Basic"
        )
      }
    }
  }

  # Flatten EKS clusters for entity creation
  eks_entities = {
    for key, cluster in var.eks_clusters : key => {
      identifier = "${key}-${var.namespace}"
      title      = key
      blueprint  = local.bp_compute_instance
      properties = {
        instanceId             = null
        tenant                 = "shared"
        class                  = key
        instanceType           = cluster.version
        privateIp              = null
        publicIp               = null
        subnetId               = null
        ami                    = null
        region                 = data.aws_region.current.id
        namespace              = var.subspace
        workspace              = var.namespace
        type                   = "eks"
        status                 = lower(cluster.status)
        awsUrl                 = "${local.sso_prefix}${urlencode("https://${data.aws_region.current.id}.console.aws.amazon.com/eks/home?region=${data.aws_region.current.id}#/clusters/${cluster.id}")}"
        ssmUrl                 = null
        sessionManagerUrl      = null
        awsProfile             = var.aws_profile
        patchGroup             = try(var.patch_management_by_class[key].patch_group, null)
        patchBaseline          = try(var.patch_management_by_class[key].baseline, null)
        patchBaselineOs        = try(var.patch_management_by_class[key].baseline_os, null)
        patchMaintenanceWindow = try(var.patch_management_by_class[key].maintenance_window, null)
        patchReadinessLevel    = null
      }
    }
  }

  # Flatten ECS clusters for entity creation
  ecs_entities = {
    for key, cluster in var.ecs_clusters : key => {
      identifier = "${key}-${var.namespace}"
      title      = key
      blueprint  = local.bp_compute_instance
      properties = {
        instanceId             = null
        tenant                 = "shared"
        class                  = key
        instanceType           = "Fargate"
        privateIp              = null
        publicIp               = null
        subnetId               = null
        ami                    = null
        region                 = data.aws_region.current.id
        namespace              = var.subspace
        workspace              = var.namespace
        type                   = "ecs"
        status                 = "active"
        awsUrl                 = "${local.sso_prefix}${urlencode("https://${data.aws_region.current.id}.console.aws.amazon.com/ecs/v2/clusters/${cluster.name}?region=${data.aws_region.current.id}")}"
        ssmUrl                 = null
        sessionManagerUrl      = null
        awsProfile             = var.aws_profile
        patchGroup             = null
        patchBaseline          = null
        patchBaselineOs        = null
        patchMaintenanceWindow = null
        patchReadinessLevel    = null
      }
    }
  }

  all_entities = merge(local.ec2_entities, local.eks_entities, local.ecs_entities)
}

resource "port_entity" "compute_instance" {
  for_each = local.all_entities

  identifier = each.value.identifier
  title      = each.value.title
  blueprint  = each.value.blueprint
  teams      = var.teams
  properties = {
    string_props = {
      instanceId             = each.value.properties.instanceId
      tenant                 = each.value.properties.tenant
      class                  = each.value.properties.class
      instanceType           = each.value.properties.instanceType
      privateIp              = each.value.properties.privateIp
      publicIp               = each.value.properties.publicIp
      subnetId               = each.value.properties.subnetId
      ami                    = each.value.properties.ami
      region                 = each.value.properties.region
      namespace              = each.value.properties.namespace
      workspace              = each.value.properties.workspace
      type                   = each.value.properties.type
      status                 = each.value.properties.status
      awsUrl                 = each.value.properties.awsUrl
      ssmUrl                 = each.value.properties.ssmUrl
      sessionManagerUrl      = each.value.properties.sessionManagerUrl
      awsProfile             = each.value.properties.awsProfile
      patchGroup             = each.value.properties.patchGroup
      patchBaseline          = each.value.properties.patchBaseline
      patchBaselineOs        = each.value.properties.patchBaselineOs
      patchMaintenanceWindow = each.value.properties.patchMaintenanceWindow
      patchReadinessLevel    = each.value.properties.patchReadinessLevel
    }
    number_props = {}
  }

  # Compliance properties are updated exclusively by the patch-compliance-reporter
  # Lambda via Port webhook. Ignore them so Terraform doesn't null them on apply.
  lifecycle {
    ignore_changes = [
      properties.string_props["patchComplianceStatus"],
      properties.string_props["patchLastScanTime"],
      properties.number_props["patchInstalledCount"],
      properties.number_props["patchMissingCount"],
    ]
  }

  depends_on = [port_blueprint.platformer_compute_instance]
}

# Create namespace-scoped dashboard page via Port API
# Bypasses Terraform provider's beta features requirement
# Uses YAML for human readability, converted to JSON by bash script
locals {
  page_identifier = var.namespace
  # Capitalize first letter of namespace for display in page title
  namespace_title = "${upper(substr(var.namespace, 0, 1))}${substr(var.namespace, 1, length(var.namespace))}"
  # Folder identifier is the lowercase owner (e.g. "Platform" -> "platform", "SRE" -> "sre")
  parent_folder = lower(var.owner)
  # Apostrophe rule: "Zapdos' Workspace" vs "Cloco's Workspace"
  page_title = endswith(local.namespace_title, "s") ? "${local.namespace_title}' Workspace" : "${local.namespace_title}'s Workspace"
  page_yaml = templatefile("${path.module}/templates/page-template.yaml", {
    namespace            = var.namespace
    namespace_title      = local.namespace_title
    page_title           = local.page_title
    owner                = var.owner
    parent_folder        = local.parent_folder
    readme_content       = local.readme_widget_content
    has_patch_management = var.patch_management_enabled
    has_service_urls     = length(var.service_urls) > 0
    has_artifacts        = length(var.artifact_requests) > 0
    has_storage          = length(var.storage_requests) > 0
  })
  page_json = jsonencode(yamldecode(local.page_yaml))
}

resource "local_file" "page_json" {
  content  = local.page_json
  filename = "${path.module}/.terraform/page-${var.namespace}.json"
}

resource "null_resource" "page_lifecycle" {
  count = local.is_subspace ? 0 : 1
  # Trigger recreation when namespace or page content changes
  # Store credentials in triggers so they're available during destroy
  triggers = {
    page_id          = local.page_identifier
    page_content     = local.page_json
    client_id        = var.port_client_id
    client_secret    = var.port_secret
    script_path      = "${path.module}/scripts/manage-page.sh"
    page_file        = local_file.page_json.filename
    page_permissions = local.page_permissions_json
    folder_owner     = var.owner
  }

  # Create/update page
  provisioner "local-exec" {
    command = "${self.triggers.script_path} create ${self.triggers.page_id} ${self.triggers.page_file} ${self.triggers.client_id} ${self.triggers.client_secret} '${self.triggers.page_permissions}' ${self.triggers.folder_owner}"
  }

  # Delete page on destroy
  provisioner "local-exec" {
    when       = destroy
    command    = "${self.triggers.script_path} destroy ${self.triggers.page_id} /dev/null ${self.triggers.client_id} ${self.triggers.client_secret}"
    on_failure = continue
  }

  depends_on = [
    port_entity.artifact,
    port_entity.compute_instance,
    port_entity.documentation,
    port_entity.git_commit,
    port_entity.storage,
    port_entity.tenant_entitlement,
    port_entity.service_url,
    port_entity.state_fragment,
    local_file.page_json
  ]
}

# State Fragments Catalog Page
locals {
  state_catalog_page_id = "my-states-${var.namespace}"
  # Apostrophe rule: "Zapdos' States" vs "Cloco's States"
  states_page_title = endswith(local.namespace_title, "s") ? "${local.namespace_title}' States" : "${local.namespace_title}'s States"
  state_catalog_page_json = templatefile("${path.module}/state-catalog-page.json", {
    namespace         = var.namespace
    states_page_title = local.states_page_title
    parent_folder     = local.parent_folder
  })
}

resource "local_file" "state_catalog_page_json" {
  content  = local.state_catalog_page_json
  filename = "${path.module}/.terraform/state-catalog-page-${var.namespace}.json"
}

resource "null_resource" "state_catalog_page_lifecycle" {
  count = local.is_subspace ? 0 : 1
  triggers = {
    page_id          = local.state_catalog_page_id
    page_content     = local.state_catalog_page_json
    client_id        = var.port_client_id
    client_secret    = var.port_secret
    script_path      = "${path.module}/scripts/manage-page.sh"
    page_file        = local_file.state_catalog_page_json.filename
    page_permissions = local.page_permissions_json
    folder_owner     = var.owner
  }

  # Create/update page with same permissions as workspace page
  provisioner "local-exec" {
    command = "${self.triggers.script_path} create ${self.triggers.page_id} ${self.triggers.page_file} ${self.triggers.client_id} ${self.triggers.client_secret} '${self.triggers.page_permissions}' ${self.triggers.folder_owner}"
  }

  # Delete page on destroy
  provisioner "local-exec" {
    when       = destroy
    command    = "${self.triggers.script_path} destroy ${self.triggers.page_id} /dev/null ${self.triggers.client_id} ${self.triggers.client_secret}"
    on_failure = continue
  }

  depends_on = [
    port_entity.state_fragment,
    local_file.state_catalog_page_json
  ]
}

# Artifacts Catalog Page
locals {
  artifact_catalog_page_id = "my-artifacts-${var.namespace}"
  # Apostrophe rule: "Zapdos' Artifacts" vs "Cloco's Artifacts"
  artifacts_page_title = endswith(local.namespace_title, "s") ? "${local.namespace_title}' Artifacts" : "${local.namespace_title}'s Artifacts"
  artifact_catalog_page_json = templatefile("${path.module}/artifact-catalog-page.json", {
    namespace            = var.namespace
    artifacts_page_title = local.artifacts_page_title
    parent_folder        = local.parent_folder
  })
}

resource "local_file" "artifact_catalog_page_json" {
  content  = local.artifact_catalog_page_json
  filename = "${path.module}/.terraform/artifact-catalog-page-${var.namespace}.json"
}

resource "null_resource" "artifact_catalog_page_lifecycle" {
  count = local.is_subspace ? 0 : 1
  triggers = {
    page_id          = local.artifact_catalog_page_id
    page_content     = local.artifact_catalog_page_json
    client_id        = var.port_client_id
    client_secret    = var.port_secret
    script_path      = "${path.module}/scripts/manage-page.sh"
    page_file        = local_file.artifact_catalog_page_json.filename
    page_permissions = local.page_permissions_json
    folder_owner     = var.owner
  }

  provisioner "local-exec" {
    command = "${self.triggers.script_path} create ${self.triggers.page_id} ${self.triggers.page_file} ${self.triggers.client_id} ${self.triggers.client_secret} '${self.triggers.page_permissions}' ${self.triggers.folder_owner}"
  }

  provisioner "local-exec" {
    when       = destroy
    command    = "${self.triggers.script_path} destroy ${self.triggers.page_id} /dev/null ${self.triggers.client_id} ${self.triggers.client_secret}"
    on_failure = continue
  }

  depends_on = [
    port_entity.artifact,
    local_file.artifact_catalog_page_json
  ]
}
