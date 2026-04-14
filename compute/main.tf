# Local variables for tenant × class × count expansion
locals {
  # All unique tenants across all entitled classes (for module-level operations)
  effective_tenants = sort(distinct(flatten(values(var.tenants_by_class))))

  # Filter application requests by type
  # Compute module handles user-data and helm deployment types
  user_data_application_requests = [
    for req in var.application_requests : req
    if req.type == "user-data"
  ]

  helm_application_requests = [
    for req in var.application_requests : req
    if req.type == "helm"
  ]

  # Type-based routing: Filter classes by type, only including classes with entitled tenants
  # EC2 classes (type: ec2) - virtual machine instances
  ec2_classes = {
    for class_name, class_config in var.config : class_name => class_config
    if class_config.type == "ec2" && length(lookup(var.tenants_by_class, class_name, [])) > 0
  }

  # EKS classes (type: eks) - Kubernetes clusters
  eks_classes = {
    for class_name, class_config in var.config : class_name => class_config
    if class_config.type == "eks" && length(lookup(var.tenants_by_class, class_name, [])) > 0
  }

  # ECS classes (type: ecs) - Container clusters
  ecs_classes = {
    for class_name, class_config in var.config : class_name => class_config
    if class_config.type == "ecs" && length(lookup(var.tenants_by_class, class_name, [])) > 0
  }

  # ── Ingress Processing ────────────────────────────────────────────
  # Split ingress rules into HTTP (direct SG rules) and HTTPS (ALB) sets.

  # HTTP ingress rules: direct security group rules (protocol = "http")
  http_ingress_rules = merge([
    for class_name, class_config in local.ec2_classes : {
      for rule in coalesce(class_config.ingress, []) : "${class_name}-${rule.port}" => {
        security_group_id = aws_security_group.class[class_name].id
        port              = rule.port
        cidrs             = rule.cidrs
      }
      if rule.protocol == "http" && contains(keys(aws_security_group.class), class_name)
    }
  ]...)

  # Reverse lookup: compute class name -> alias FQDN (first alias wins if multiple)
  # Used to override HTTPS_HOSTNAME so the server knows its public identity
  alias_by_class = {
    for fqdn, class_name in var.domain_aliases : class_name => fqdn...
  }
  alias_fqdn_by_class = {
    for class_name, fqdns in local.alias_by_class : class_name => fqdns[0]
  }

  # HTTPS classes: classes with at least one protocol = "https" ingress rule
  # Gated on domain_enabled (config-derived, plan-time safe) - not certificate_arn (apply-time)
  https_classes = var.domain_enabled ? {
    for class_name, class_config in local.ec2_classes : class_name => {
      class_config = class_config
      https_rules  = [for rule in coalesce(class_config.ingress, []) : rule if rule.protocol == "https"]
    }
    if length([for rule in coalesce(class_config.ingress, []) : rule if rule.protocol == "https"]) > 0
  } : {}

  # Network resolution: Determine which network each class should use (applies to EC2 and EKS)
  # If network_name specified, look it up. If null/missing, no network (error for EKS, default VPC for EC2).
  class_networks = {
    for class_name, class_config in var.config : class_name => (
      # If network_name specified, look it up in networks map
      class_config.network_name != null
      ? var.networks[class_config.network_name]
      # Otherwise, no network
      : null
    )
  }

  # VPC ID resolution for security groups: custom network or default VPC
  # EC2 instances always need security groups, even in default VPC
  # Only create VPC mappings for classes that have a resolvable VPC
  class_vpc_ids = {
    for class_name, class_config in local.ec2_classes : class_name => (
      # If class has explicit network, use that VPC
      local.class_networks[class_name] != null
      ? local.class_networks[class_name].network_summary.vpc_id
      # Otherwise, use default VPC (from "default" network module) if it exists
      : var.networks["default"].network_summary.vpc_id
    )
    # Only include classes that have a resolvable VPC (explicit network or default exists)
    if local.class_networks[class_name] != null || contains(keys(var.networks), "default")
  }

  # EKS subnet resolution:
  # 1. Explicit subnet_ids in class config (highest priority - for custom scenarios)
  # 2. Subnets from class's resolved network (if network_name specified)
  # 3. Public subnets from "default" network (fallback - always exists from main.tf)
  # Note: Using public subnets for EKS node groups (require MapPublicIpOnLaunch=true)
  eks_cluster_subnets = {
    for class_name, class_config in local.eks_classes : class_name => (
      # Explicit subnet_ids provided in class config
      class_config.subnet_ids != null ? class_config.subnet_ids :
      # Use public subnets from this class's network (if network_name specified)
      local.class_networks[class_name] != null ?
      local.class_networks[class_name].subnets_by_tier["public"].ids :
      # Fallback to "default" network's public subnets (always exists from main.tf)
      var.networks["default"].subnets_by_tier["public"].ids
    )
  }

  # Flatten tenants × EC2 classes × count into instance map
  # Each entry: "tenant-code-class-name" or "tenant-code-class-name-N" => { instance config }
  tenant_instances = merge([
    for tenant in local.effective_tenants : merge([
      for class_name, class_config in local.ec2_classes : {
        for idx in range(class_config.count) :
        # Instance key naming: always use "tenant-class-0", "tenant-class-1", etc.
        "${tenant}-${class_name}-${idx}" => {
          ami_filter    = class_config.ami_filter
          instance_type = class_config.instance_type
          volume_size   = class_config.volume_size
          volume_type   = class_config.volume_type
          description   = class_config.description
          tenant        = tenant
          class         = class_name
          instance_idx  = idx
        }
      }
      # Filter: tenant must be entitled to this class
      if contains(lookup(var.tenants_by_class, class_name, []), tenant)
    ]...)
  ]...)

  # Subnet assignment for EC2 instances (VPC targeting)
  # Priority order:
  # 1. Explicit subnet_ids in class config (highest priority - for custom scenarios)
  # 2. Subnet tier in class config (e.g., "private", "public", "intra")
  # 3. Default to private subnets if class has a network
  # 4. No subnet (default VPC behavior) if no network for this class
  # Instances are distributed across AZs using modulo on instance_idx
  instance_subnet_assignments = {
    for instance_key, instance_config in local.tenant_instances : instance_key => (
      # Get the network for this instance's class
      local.class_networks[instance_config.class] != null ? (
        # 1. Explicit subnet_ids provided in class config
        local.ec2_classes[instance_config.class].subnet_ids != null
        ? local.ec2_classes[instance_config.class].subnet_ids[instance_config.instance_idx % length(local.ec2_classes[instance_config.class].subnet_ids)]
        # 2. Subnet tier specified in class config (e.g., "private", "public", "intra")
        : local.ec2_classes[instance_config.class].subnet_tier != null
        ? local.class_networks[instance_config.class].subnets_by_tier[local.ec2_classes[instance_config.class].subnet_tier].ids[instance_config.instance_idx % length(local.class_networks[instance_config.class].subnets_by_tier[local.ec2_classes[instance_config.class].subnet_tier].ids)]
        # 3. Default to private subnets
        : local.class_networks[instance_config.class].subnets_by_tier["private"].ids[instance_config.instance_idx % length(local.class_networks[instance_config.class].subnets_by_tier["private"].ids)]
        ) : (
        # 4. No network for this class - use default VPC (subnet_id = null)
        null
      )
    )
  }

  # Flatten instances × parameters into parameter resources (dependency inversion pattern)
  # For each instance, create parameters defined by other modules via instance_parameters variable
  instance_parameters = merge([
    for instance_key, instance_config in local.tenant_instances : {
      for param_idx, param_def in var.instance_parameters :
      "${instance_key}-param-${param_idx}" => {
        instance_key     = instance_key
        instance_id      = aws_instance.tenant[instance_key].id
        path             = replace(replace(param_def.path_template, "{instance_id}", aws_instance.tenant[instance_key].id), "{username}", param_def.default_username)
        description      = param_def.description
        initial_value    = param_def.initial_value
        type             = param_def.type
        default_username = param_def.default_username
      }
    }
  ]...)

  # Group user-data applications by class (from applications module)
  user_data_apps_by_class = {
    for class_name in keys(local.ec2_classes) :
    class_name => [
      for req in local.user_data_application_requests : req
      if req.class == class_name
    ]
    if length([for req in local.user_data_application_requests : req if req.class == class_name]) > 0
  }

  # User-data script generation: Combine class user_data_script + application scripts
  # For each EC2 class, build a composite user-data script if applications exist
  user_data_by_class = {
    for class_name, class_config in local.ec2_classes : class_name => (
      # Has user-data applications - use template to combine
      lookup(local.user_data_apps_by_class, class_name, null) != null
      ? templatefile("${path.module}/templates/user-data-wrapper.sh.tftpl", {
        base_script         = class_config.user_data_script != null ? file("${path.module}/scripts/${class_config.user_data_script}") : ""
        application_scripts = local.user_data_apps_by_class[class_name]
      })
      # No applications, use base script or null
      : class_config.user_data_script != null ? file("${path.module}/scripts/${class_config.user_data_script}") : null
    )
  }

  # Application Requests: Expand applications per tenant × class
  # SSM/Ansible/Helm are tenant-specific (separate deployments per tenant)
  # user-data is class-level only (runs at instance launch, not per-tenant)
  application_requests = concat(
    # Tenant-specific applications (SSM, Ansible, Helm)
    flatten([
      for tenant in local.effective_tenants : flatten([
        for class_name, class_config in var.config : [
          for app in lookup(class_config, "applications", []) : {
            class  = class_name
            tenant = tenant
            type   = app.type

            # Script-based deployment fields
            script = app.type == "ssm" ? app.script : null
            # Auto-inject TENANT, DEPLOYMENT_NAMESPACE, AWS_REGION, and HTTPS_HOSTNAME parameters
            params = app.type == "ssm" || app.type == "ansible" ? merge(
              coalesce(app.params, {}),
              {
                TENANT               = tenant
                DEPLOYMENT_NAMESPACE = var.namespace
                AWS_REGION           = data.aws_region.current.id
              },
              # Inject HTTPS hostname: prefer alias FQDN, then per-instance ALB FQDN
              contains(keys(local.alias_fqdn_by_class), class_name) ? {
                HTTPS_HOSTNAME = local.alias_fqdn_by_class[class_name]
              } : contains(keys(local.https_instances), "${tenant}-${class_name}-0") ? {
                HTTPS_HOSTNAME = local.https_instances["${tenant}-${class_name}-0"].fqdn
              } : {},
              # Inject swap size when configured on the class
              class_config.swap_size > 0 ? {
                SWAP_SIZE_GB = tostring(class_config.swap_size)
              } : {}
            ) : null

            # Targeting: Class tag for class-specific deployments (enables different configs per class)
            # This allows ArchPACS depot/database servers to receive different playbooks
            # and Archshare instances to share the same playbook (they share the same class)
            target_tag_key   = app.type == "ssm" || app.type == "ansible" ? "Class" : null
            target_tag_value = app.type == "ssm" || app.type == "ansible" ? class_name : null

            # Ansible fields
            playbook      = app.type == "ansible" ? app.playbook : null
            playbook_file = app.type == "ansible" ? lookup(app, "playbook_file", "playbook.yml") : null

            # Helm fields (tenant-specific namespace - always suffix with tenant)
            chart        = app.type == "helm" ? app.chart : null
            repository   = app.type == "helm" ? app.repository : null
            version      = app.type == "helm" ? app.version : null
            namespace    = app.type == "helm" ? "${coalesce(app.namespace, class_name)}-${tenant}" : null
            release_name = app.type == "helm" ? "${coalesce(app.release_name, app.chart)}-${tenant}" : null
            values       = app.type == "helm" ? app.values : null
            wait         = app.type == "helm" ? coalesce(app.wait, true) : null
            timeout      = app.type == "helm" ? coalesce(app.timeout, 300) : null
          }
          # Filter: tenant-specific types only + class entitlement
          # Ansible apps on 1-master classes are excluded here - they are emitted
          # per-instance with rank/addr injection in local.cluster_application_requests
          if(app.type == "ssm" || app.type == "ansible" || app.type == "helm") &&
          !(app.type == "ansible" && class_config.mode == "1-master") &&
          contains(lookup(var.tenants_by_class, class_name, []), tenant)
        ]
      ])
    ]),
    # Class-level applications (user-data only - not tenant-specific)
    # Only include classes with entitled tenants
    flatten([
      for class_name, class_config in var.config : [
        for app in lookup(class_config, "applications", []) : {
          class  = class_name
          tenant = null
          type   = app.type

          # user-data fields
          script           = app.type == "user-data" ? app.script : null
          params           = app.type == "user-data" ? app.params : null
          target_tag_key   = app.type == "user-data" ? "Class" : null
          target_tag_value = app.type == "user-data" ? class_name : null

          # Null for other types
          playbook      = null
          playbook_file = null
          chart         = null
          repository    = null
          version       = null
          namespace     = null
          release_name  = null
          values        = null
          wait          = null
          timeout       = null
        }
        if app.type == "user-data" && length(lookup(var.tenants_by_class, class_name, [])) > 0
      ]
    ])
  )
}

# ============================================================================
# Cluster Application Requests (mode: 1-master)
# ============================================================================
# For EC2 classes with mode = "1-master", a single cluster entry is emitted
# per (tenant, class, app). All node instance IDs and their per-node
# variables (NODE_RANK, MASTER_ADDR, etc.) are bundled into a `hosts` list.
# The orchestrator builds a multi-host inventory so Ansible runs all nodes
# in parallel via forks, with per-host vars delivered as host_vars.

locals {
  cluster_application_requests = flatten([
    for tenant in local.effective_tenants : flatten([
      for class_name, class_config in local.ec2_classes : [
        for app in coalesce(class_config.applications, []) : {
          class  = class_name
          tenant = tenant
          type   = app.type

          # No script or helm fields - cluster mode is ansible-only
          script = null

          # Common params shared across all nodes
          params = merge(
            coalesce(app.params, {}),
            {
              TENANT               = tenant
              DEPLOYMENT_NAMESPACE = var.namespace
              AWS_REGION           = data.aws_region.current.id
            },
            # Inject swap size when configured on the class
            class_config.swap_size > 0 ? {
              SWAP_SIZE_GB = tostring(class_config.swap_size)
            } : {}
          )

          # Tag-based targeting is bypassed - cluster uses host-list targeting
          target_tag_key   = null
          target_tag_value = null
          targeting_mode   = "cluster"
          targets          = null
          instance_id      = null

          # Per-node host entries: instance ID + neutral compute-level structural facts.
          # These are infrastructure vocabulary only - playbooks map them to their
          # own variable names via set_fact rather than coupling compute to app details.
          #   CLUSTER_NODE_INDEX - zero-based position of this node
          #   CLUSTER_SIZE       - total number of nodes in the cluster
          #   CLUSTER_MASTER_IP  - private IP of the rank-0 (master) instance
          #   CLUSTER_PORT       - rendezvous port from cluster_port class config
          hosts = [
            for idx in range(class_config.count) : {
              instance_id = aws_instance.tenant["${tenant}-${class_name}-${idx}"].id
              vars = merge(
                {
                  CLUSTER_NODE_INDEX = tostring(idx)
                  CLUSTER_SIZE       = tostring(class_config.count)
                  CLUSTER_MASTER_IP  = aws_instance.tenant["${tenant}-${class_name}-0"].private_ip
                  CLUSTER_PORT       = tostring(coalesce(class_config.cluster_port, 29500))
                },
                # Inject HTTPS hostname: prefer alias FQDN, then per-instance ALB FQDN
                contains(keys(local.alias_fqdn_by_class), class_name) ? {
                  HTTPS_HOSTNAME = local.alias_fqdn_by_class[class_name]
                } : contains(keys(local.https_instances), "${tenant}-${class_name}-${idx}") ? {
                  HTTPS_HOSTNAME = local.https_instances["${tenant}-${class_name}-${idx}"].fqdn
                } : {}
              )
            }
          ]

          # Ansible fields - include playbook_source_path so these requests
          # can go directly to configuration-management without applications module enrichment
          playbook             = app.playbook
          playbook_file        = lookup(app, "playbook_file", "playbook.yml")
          playbook_source_path = "applications/ansible/${app.playbook}"

          # Unused fields
          chart        = null
          repository   = null
          version      = null
          namespace    = null
          release_name = null
          values       = null
          wait         = null
          timeout      = null
        }
        if app.type == "ansible"
      ]
      if contains(lookup(var.tenants_by_class, class_name, []), tenant) &&
      class_config.mode == "1-master"
    ])
  ])
}

# ============================================================================
# Preflight Checks - Validate dependencies before creating AWS resources
# ============================================================================

locals {
  required_tools = {
    helm = {
      type     = "discrete"
      commands = ["helm"]
    }
    kubectl = {
      type     = "discrete"
      commands = ["kubectl"]
    }
    aws = {
      type     = "discrete"
      commands = ["aws"]
    }
  }
}

module "preflight" {
  source = "../preflight"

  # Only validate k8s tools when EKS classes exist
  required_tools = length(local.eks_classes) > 0 ? {
    helm    = local.required_tools["helm"]
    kubectl = local.required_tools["kubectl"]
    aws     = local.required_tools["aws"]
  } : {}
}

# ============================================================================
# EC2 Resources (type: ec2)
# ============================================================================

# EC2 instances for tenants
# DHMC (Default Host Management Configuration) automatically registers instances with SSM
# IAM instance profile is conditionally attached when instances need S3 access (e.g., for application scripts)
resource "aws_instance" "tenant" {
  for_each = local.tenant_instances

  ami           = lookup(var.built_amis, each.value.class, local.resolved_amis[each.value.class])
  instance_type = each.value.instance_type

  # IAM instance profile for S3 access (when classes have applications)
  # Instance profile is created by the access module and returned via dependency inversion
  iam_instance_profile = local.has_applications ? lookup(var.access_instance_profile_names, "compute-instance", null) : null

  # VPC targeting: automatically place instances in custom VPC if network module is available
  # Falls back to default VPC if no network (subnet_id = null)
  subnet_id = local.instance_subnet_assignments[each.key]

  # Public IP association (for instances in public subnets)
  associate_public_ip_address = local.ec2_classes[each.value.class].associate_public_ip

  # Security groups: class security group + any additional groups
  vpc_security_group_ids = concat(
    # Class security group (if VPC is available and security group was created)
    contains(keys(aws_security_group.class), each.value.class) ? [aws_security_group.class[each.value.class].id] : [],
    # Additional security groups from class config
    coalesce(local.ec2_classes[each.value.class].security_group_ids, [])
  )

  # User-data script: Composite of base script + application scripts (type: user-data)
  # Applications module provides user-data scripts via dependency inversion
  # Use plain user_data (AWS handles base64 encoding automatically)
  user_data                   = local.user_data_by_class[each.value.class]
  user_data_replace_on_change = true

  root_block_device {
    volume_size = each.value.volume_size
    volume_type = each.value.volume_type
    encrypted   = true
  }

  tags = merge(
    {
      Name          = "${each.key}-${var.namespace}"
      Tenant        = each.value.tenant
      Class         = each.value.class                  # Used for instance classification
      Namespace     = var.namespace                     # Used for deployment isolation (multi-developer/multi-environment support)
      InstanceIndex = tostring(each.value.instance_idx) # Zero-based index within class; used for cluster targeting
    },
    # Add Description tag if description is non-empty
    # WARNING: Description appears in AWS console, billing reports, and Cost Explorer
    each.value.description != "" ? { Description = each.value.description } : {},
    # NOTE: Patch Group tag is managed by configuration-management module
    # (static targeting via aws_ec2_tag, dynamic targeting via Lambda)
    # Add class-specific tags (e.g., OS, Platform for maintenance window targeting)
    local.ec2_classes[each.value.class].tags
  )

  lifecycle {
    # Ignore external changes to Patch Group tag
    # Lambda-based dynamic targeting may apply this tag outside of Terraform
    ignore_changes = [
      tags["Patch Group"],
      tags_all["Patch Group"]
    ]
  }
}

# Parameter Store entries for instances (dependency inversion pattern)
# Other modules define parameters via instance_parameters variable; compute module creates the resources
resource "aws_ssm_parameter" "instance" {
  for_each = local.instance_parameters

  name        = each.value.path
  description = each.value.description
  type        = each.value.type
  value       = each.value.initial_value

  tags = {
    Name       = each.value.path
    InstanceId = each.value.instance_id
  }

  lifecycle {
    # SSM documents will update the value and description; don't revert changes
    ignore_changes = [value, description]
  }
}

# ============================================================================
# EKS Resources (type: eks)
# ============================================================================

# IAM role for EKS cluster
resource "aws_iam_role" "eks_cluster" {
  for_each = local.eks_classes

  name = "${each.key}-cluster-${var.namespace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = merge(
    {
      Name      = "${each.key}-cluster-role-${var.namespace}"
      Class     = each.key
      Namespace = var.namespace
    },
    each.value.tags
  )
}

# Attach required policies to EKS cluster role
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  for_each = local.eks_classes

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster[each.key].name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  for_each = local.eks_classes

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster[each.key].name
}

# IAM role for EKS node group
resource "aws_iam_role" "eks_node_group" {
  for_each = local.eks_classes

  name = "${each.key}-node-${var.namespace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge(
    {
      Name      = "${each.key}-node-role-${var.namespace}"
      Class     = each.key
      Namespace = var.namespace
    },
    each.value.tags
  )
}

# Attach required policies to EKS node group role
resource "aws_iam_role_policy_attachment" "eks_node_worker_policy" {
  for_each = local.eks_classes

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group[each.key].name
}

resource "aws_iam_role_policy_attachment" "eks_node_cni_policy" {
  for_each = local.eks_classes

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group[each.key].name
}

resource "aws_iam_role_policy_attachment" "eks_node_container_registry" {
  for_each = local.eks_classes

  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group[each.key].name
}

# EKS Cluster
resource "aws_eks_cluster" "cluster" {
  for_each = local.eks_classes

  name     = "${each.key}-${var.namespace}"
  role_arn = aws_iam_role.eks_cluster[each.key].arn
  version  = each.value.version

  vpc_config {
    subnet_ids              = local.eks_cluster_subnets[each.key]
    endpoint_private_access = coalesce(each.value.endpoint_private_access, true)
    endpoint_public_access  = coalesce(each.value.endpoint_public_access, false)
  }

  upgrade_policy {
    support_type = each.value.support_type
  }

  # Enable API-based authentication for SSO user access
  # Preserves cluster creator admin permissions to avoid forced recreation
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(
    {
      Name      = "${each.key}-${var.namespace}"
      Class     = each.key
      Namespace = var.namespace
    },
    each.value.tags
  )

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# EKS Node Groups
resource "aws_eks_node_group" "node_group" {
  for_each = merge([
    for class_name, class_config in local.eks_classes : {
      for ng_name, ng_config in coalesce(class_config.node_groups, {}) :
      "${class_name}-${ng_name}" => merge(ng_config, {
        cluster_name    = class_name
        node_group_name = ng_name
      })
    }
  ]...)

  cluster_name    = aws_eks_cluster.cluster[each.value.cluster_name].name
  node_group_name = "${each.value.node_group_name}-${var.namespace}"
  node_role_arn   = aws_iam_role.eks_node_group[each.value.cluster_name].arn
  subnet_ids      = local.eks_cluster_subnets[each.value.cluster_name]

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  instance_types = each.value.instance_types

  labels = coalesce(each.value.labels, {})

  dynamic "taint" {
    for_each = coalesce(each.value.taints, [])
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(
    {
      Name      = "${each.value.cluster_name}-${each.value.node_group_name}-${var.namespace}"
      Class     = each.value.cluster_name
      Namespace = var.namespace
    },
    local.eks_classes[each.value.cluster_name].tags
  )

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker_policy,
    aws_iam_role_policy_attachment.eks_node_cni_policy,
    aws_iam_role_policy_attachment.eks_node_container_registry
  ]
}

# EKS Addons
# Install addons declared in the EKS class config (e.g., aws-ebs-csi-driver, coredns)
# Flatten: cluster × addon → unique key for resource creation
locals {
  eks_addons = merge([
    for class_name, class_config in local.eks_classes : {
      for addon in coalesce(class_config.addons, []) :
      "${class_name}-${addon}" => {
        cluster_name = class_name
        addon_name   = addon
      }
    }
  ]...)
}

# Pod Identity roles for EKS addons
# Pod Identity is simpler than IRSA: no OIDC provider, no TLS certs, no complex trust conditions.
# Just an IAM role with eks-pods trust + an aws_eks_pod_identity_association resource.

resource "aws_iam_role" "ebs_csi_driver" {
  for_each = {
    for class_name, class_config in local.eks_classes : class_name => class_config
    if contains(coalesce(class_config.addons, []), "aws-ebs-csi-driver")
  }

  name = "${each.key}-ebs-csi-${var.namespace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = {
    Namespace = var.namespace
    Purpose   = "ebs-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  for_each = aws_iam_role.ebs_csi_driver

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = each.value.name
}

resource "aws_eks_pod_identity_association" "ebs_csi_driver" {
  for_each = aws_iam_role.ebs_csi_driver

  cluster_name    = aws_eks_cluster.cluster[each.key].name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = each.value.arn
}

# Generic Pod Identity Associations (dependency inversion from upstream modules)
# Modules like observability emit pod_identity_requests; compute creates the roles + associations
locals {
  pod_identity_map = {
    for req in var.pod_identity_requests :
    "${req.cluster_class}-${req.name}" => req
    if contains(keys(local.eks_classes), req.cluster_class)
  }
}

resource "aws_iam_role" "pod_identity" {
  for_each = local.pod_identity_map
  name     = "${each.value.name}-${var.namespace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Namespace = var.namespace
    Purpose   = each.value.name
  }
}

resource "aws_iam_role_policy" "pod_identity" {
  for_each = local.pod_identity_map
  name     = each.value.name
  role     = aws_iam_role.pod_identity[each.key].name
  policy   = each.value.policy
}

resource "aws_eks_pod_identity_association" "pod_identity" {
  for_each = local.pod_identity_map

  cluster_name    = aws_eks_cluster.cluster[each.value.cluster_class].name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.pod_identity[each.key].arn
}

resource "aws_eks_addon" "addon" {
  for_each = local.eks_addons

  cluster_name = aws_eks_cluster.cluster[each.value.cluster_name].name
  addon_name   = each.value.addon_name

  depends_on = [
    aws_eks_node_group.node_group,
    aws_eks_pod_identity_association.ebs_csi_driver,
    aws_eks_pod_identity_association.pod_identity
  ]
}

# Kubeconfig Management
# Automatically manages kubeconfig entries for EKS clusters
# - On apply: Adds/updates cluster context in ~/.kube/config
# - On destroy: Removes cluster context from ~/.kube/config
resource "null_resource" "kubeconfig_manager" {
  for_each = local.eks_classes

  # Add/update kubeconfig entry when cluster is created
  # Use target account profile for CLI commands (Terraform uses 'default' but CLI needs direct access)
  provisioner "local-exec" {
    command = "${path.module}/scripts/add-eks-kubeconfig.sh ${aws_eks_cluster.cluster[each.key].name} ${data.aws_region.current.id} ${data.aws_caller_identity.current.account_id} ${each.key} example-platform-dev"
  }

  # Remove kubeconfig entry when cluster is destroyed
  # Must delete context, cluster, AND user entries to fully clean up
  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/remove-eks-kubeconfig.sh ${self.triggers.cluster_arn} ${self.triggers.cluster_name} ${self.triggers.context_name}"
  }

  depends_on = [
    aws_eks_cluster.cluster,
    aws_eks_node_group.node_group
  ]

  triggers = {
    cluster_arn  = aws_eks_cluster.cluster[each.key].arn
    cluster_name = aws_eks_cluster.cluster[each.key].name
    context_name = each.key
  }
}

# EKS Access Entry for SSO Users
# NOTE: Disabled - cluster creator already has admin access via:
#   access_config { bootstrap_cluster_creator_admin_permissions = true }
# AWS automatically creates an access entry for the IAM principal that creates the cluster.
# Attempting to explicitly create an access entry for the same principal results in a 409 conflict.
#
# If you need to grant access to OTHER IAM principals (not the creator), add them here.
# Example:
#   resource "aws_eks_access_entry" "additional_admin" {
#     for_each      = local.eks_classes
#     cluster_name  = aws_eks_cluster.cluster[each.key].name
#     principal_arn = "arn:aws:iam::123456789012:role/SomeOtherRole"
#     type          = "STANDARD"
#   }

# ============================================================================
# ECS Resources (type: ecs)
# ============================================================================

# ECS Clusters
resource "aws_ecs_cluster" "cluster" {
  for_each = local.ecs_classes

  name = "${each.key}-${var.namespace}"

  dynamic "setting" {
    for_each = each.value.container_insights ? [1] : []
    content {
      name  = "containerInsights"
      value = "enabled"
    }
  }

  tags = merge(
    {
      Name      = "${each.key}-${var.namespace}"
      Class     = each.key
      Namespace = var.namespace
    },
    each.value.tags
  )
}
