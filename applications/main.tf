# Applications Module
# Purely declarative - enriches application requests with deployment-specific metadata
# Deployment-agnostic: no knowledge of SSM, S3, Helm, or any deployment mechanism
#
# Strategy:
# 1. Receive application requirements from compute module + standalone config
# 2. Transform standalone config into request objects
# 3. Add deployment-specific enrichment (script paths for script-based, defaults for Helm)
# 4. Route by deployment type (ssm, compose, ansible, user-data, or helm)
# 5. Export type-specific requests for appropriate modules to deploy

locals {
  # Standalone applications (services.applications). `profiles` is the one
  # convenience on top of `environment` (it becomes COMPOSE_PROFILES); nothing
  # here knows any other variable by name.
  standalone_apps = {
    for name, app in var.config : name => merge(app, {
      environment = merge(
        length(app.profiles) > 0 ? { COMPOSE_PROFILES = join(",", app.profiles) } : {},
        app.environment
      )

      # Targeting for SSM associations (ignored when `hosts` is set)
      targeting_mode = try(app.targeting.mode, "wildcard")
      targets = try(app.targeting.mode, "wildcard") == "tags" ? [
        for tag_key, tag_values in coalesce(try(app.targeting.tags, null), {}) : {
          key    = "tag:${tag_key}"
          values = tag_values
        }
      ] : null

      # compose: the stack's source and host settings, passed to
      # applications/scripts/compose-stack.sh as parameters
      stack_params = app.type == "compose" ? {
        STACK_NAME       = name
        STACK_REPOSITORY = app.repository == null ? "" : app.repository
        STACK_REF        = coalesce(app.ref, "HEAD")
        STACK_PATH       = app.path
        STACK_DIRECTORY  = coalesce(app.directory, "/opt/stacks/${name}")
        STACK_PORTS      = join(" ", app.ports)
      } : {}
    })
  }

  # One deployment per app, or one per entry in its `hosts` map. A host entry
  # pins the deployment to one instance (EC2 or hybrid mi-) and layers its own
  # environment over the app's, for values that differ per host (hostnames).
  standalone_deployments = flatten([
    for name, app in local.standalone_apps : length(app.hosts) == 0 ? [
      {
        key         = name
        app         = name
        instance_id = null
        environment = app.environment
      }
      ] : [
      for host, host_config in app.hosts : {
        key         = "${name}-${host}"
        app         = name
        instance_id = host_config.instance_id
        environment = merge(app.environment, host_config.environment)
      }
    ]
  ])

  # Request objects for the standalone deployments
  standalone_application_requests = [
    for d in local.standalone_deployments : {
      class  = d.key
      tenant = null
      type   = local.standalone_apps[d.app].type

      # Script-based deployment fields (compose runs the generic stack script)
      script      = local.standalone_apps[d.app].type == "compose" ? "compose-stack.sh" : local.standalone_apps[d.app].script
      params      = merge(local.standalone_apps[d.app].stack_params, local.standalone_apps[d.app].params)
      environment = d.environment

      # compose stacks are torn down on the host when removed from state
      teardown = local.standalone_apps[d.app].type == "compose"

      # Targeting: standalone apps don't use compute tag-based targeting
      target_tag_key   = null
      target_tag_value = null
      targeting_mode   = d.instance_id != null ? "instance" : local.standalone_apps[d.app].targeting_mode
      targets          = d.instance_id != null ? null : local.standalone_apps[d.app].targets
      instance_id      = d.instance_id

      # Ansible fields
      playbook      = local.standalone_apps[d.app].playbook
      playbook_file = local.standalone_apps[d.app].playbook_file

      # Helm fields (not applicable for standalone)
      chart        = null
      repository   = null
      version      = null
      namespace    = null
      release_name = null
      values       = null
      wait         = null
      timeout      = null
    }
  ]

  # Merge compute-sourced requests with standalone requests
  all_application_requests = concat(var.application_requests, local.standalone_application_requests)

  # Auto-discover module directories that contain ansible playbooks
  # Any top-level directory with an ansible/ subdirectory is a candidate
  # NOTE: fileset only returns files, not directories, so we must match files within ansible/
  ansible_module_dirs = distinct([
    for f in fileset(path.root, "*/ansible/**") : split("/", f)[0]
    if split("/", f)[0] != "applications" # Exclude shared applications/ansible (handled as fallback)
  ])

  # Pre-compute playbook paths for Ansible deployments
  # Supports dual-source playbooks: module-specific or shared
  # Use ellipsis to handle duplicate class-playbook combinations (same playbook used across multiple tenants)
  #
  # Path resolution order:
  # 1. Check each known module directory (e.g., iopacs/ansible/<playbook>/)
  # 2. Fall back to shared path (applications/ansible/<playbook>/)
  #
  # NOTE: The previous approach used split("-", class)[0] to guess the module prefix, but this
  # breaks for multi-segment deployment names (e.g., class "ec2-poc-depot" → prefix "ec2", not "iopacs").
  # Instead, we search all known module directories for the playbook.
  ansible_playbook_paths = merge([
    for req in local.all_application_requests : {
      "${req.class}-${req.playbook}" = req.type == "ansible" && req.playbook != null ? {
        playbook_file = coalesce(req.playbook_file, "playbook.yml")
        shared_path   = "${path.root}/applications/ansible/${req.playbook}"
        # Search known module directories, then fall back to shared applications/ansible/
        playbook_source_path = try(
          [for mod in local.ansible_module_dirs :
            "${path.root}/${mod}/ansible/${req.playbook}"
            if fileexists("${path.root}/${mod}/ansible/${req.playbook}/${coalesce(req.playbook_file, "playbook.yml")}")
          ][0],
          "${path.root}/applications/ansible/${req.playbook}"
        )
      } : null
    } if req.type == "ansible" && req.playbook != null
  ]...)

  # Enrich ALL application requests with deployment-specific metadata
  enriched_requests = [
    for req in local.all_application_requests : merge(req,
      # Script-based deployments (SSM/compose/user-data): add script source path
      contains(["ssm", "compose", "user-data"], req.type) ? {
        script_source_path = "${path.root}/applications/scripts/${req.script}"
      } :
      # Ansible deployments: add playbook directory path from pre-computed map
      req.type == "ansible" && req.playbook != null ? {
        playbook_source_path = local.ansible_playbook_paths["${req.class}-${req.playbook}"].playbook_source_path
        playbook_file        = local.ansible_playbook_paths["${req.class}-${req.playbook}"].playbook_file
      } :
      # Helm deployments: add release_name default if not provided
      req.type == "helm" && req.chart != null ? {
        release_name = coalesce(req.release_name, req.chart)
      } : {}
    )
  ]

  # ── Preflight: Ansible playbook validation ──────────────────────────────
  # Ansible reserves certain variable names (e.g., "namespace") that cause
  # warnings or subtle failures when used in playbook vars blocks.
  # Scan all resolved playbook files at plan time and fail early if violations found.
  ansible_reserved_var_names = ["namespace"]

  # Deduplicated set of playbook files to check (keyed by path to avoid re-reading)
  # Use ellipsis (...) to handle multiple classes referencing the same playbook file
  ansible_playbook_files = merge([
    for key, path_info in local.ansible_playbook_paths : {
      "${path_info.playbook_source_path}/${path_info.playbook_file}" = {
        playbook    = key
        source_path = path_info.playbook_source_path
        file        = path_info.playbook_file
      }
    }
    if path_info != null
  ]...)

  # Check each playbook file for reserved variable declarations
  # Pattern: a line with `<whitespace><reserved_name>:` in a vars context
  ansible_reserved_var_violations = flatten([
    for file_path, info in local.ansible_playbook_files : [
      for reserved in local.ansible_reserved_var_names :
      "${info.playbook} uses reserved variable '${reserved}' (${file_path})"
      if can(regex("(?m)^\\s+${reserved}\\s*:", file(file_path)))
    ]
    if fileexists(file_path)
  ])

  # Type-based routing: Filter enriched requests by deployment type
  # SSM and compose requests → configuration-management module (SSM associations)
  ssm_requests = [
    for req in local.enriched_requests : req
    if contains(["ssm", "compose"], req.type)
  ]

  # Ansible requests → configuration-management module (ansible playbooks via SSM)
  ansible_requests = [
    for req in local.enriched_requests : req
    if req.type == "ansible"
  ]

  # User-data requests → compute module (instance launch only)
  user_data_requests = [
    for req in local.enriched_requests : req
    if req.type == "user-data"
  ]

  # Helm requests → compute module (deployed to EKS clusters)
  helm_requests = [
    for req in local.enriched_requests : req
    if req.type == "helm"
  ]
}

# ============================================================================
# Preflight Checks - Fail plan if any Ansible playbook uses reserved variables
# ============================================================================
resource "terraform_data" "ansible_preflight" {
  count = length(local.ansible_playbook_files) > 0 ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.ansible_reserved_var_violations) == 0
      error_message = "Ansible playbooks must not use reserved variable names. Violations:\n  ${join("\n  ", local.ansible_reserved_var_violations)}"
    }
  }
}
