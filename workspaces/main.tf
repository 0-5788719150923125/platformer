# Workspaces Module
# Enables workspace-specific variable overrides via terraform.tfvars.{workspace} files
#
# Usage:
#   1. Create workspace-specific tfvars file (e.g., terraform.tfvars.dev)
#   2. Switch to workspace: terraform workspace select dev
#   3. Run terraform plan/apply - workspace-specific values will be used
#
# Fallback behavior:
#   - Default workspace: always uses base terraform.tfvars values
#   - Non-default workspace without file: falls back to base terraform.tfvars values
#   - Non-default workspace with file: uses tfvars values (complete replacement per variable)

locals {
  # Metadata
  is_default_workspace  = terraform.workspace == "default"
  workspace_file_path   = "${path.root}/terraform.tfvars.${terraform.workspace}"
  workspace_file_exists = var.enabled && fileexists(local.workspace_file_path)

  # Read workspace file content as string (empty if doesn't exist)
  workspace_file_content = local.workspace_file_exists ? file(local.workspace_file_path) : ""

  # Parse aws_profile: extract value from pattern `aws_profile = "value"`
  aws_profile_raw       = try(regex("aws_profile\\s*=\\s*\"([^\"]+)\"", local.workspace_file_content)[0], null)
  requested_aws_profile = local.aws_profile_raw != null ? local.aws_profile_raw : var.default_aws_profile

  # Fall back to "default" when the requested profile doesn't exist on this
  # machine. Configs and tests may name profiles (e.g. "example-platform-dev")
  # that only exist in some environments; without this, the AWS provider fails
  # with "failed to get shared config profile" before it can do anything.
  # Sections look like "[profile name]" in ~/.aws/config and "[name]" in
  # ~/.aws/credentials. Honors AWS_CONFIG_FILE/AWS_SHARED_CREDENTIALS_FILE
  # only implicitly (we read the conventional paths; a missing file just
  # contributes nothing). null stays null - that means "AWS not configured".
  aws_shared_config = join("\n", [
    fileexists(pathexpand("~/.aws/config")) ? file(pathexpand("~/.aws/config")) : "",
    fileexists(pathexpand("~/.aws/credentials")) ? file(pathexpand("~/.aws/credentials")) : "",
  ])
  requested_profile_exists = local.requested_aws_profile != null && can(
    regex("\\[(profile )?${local.requested_aws_profile}\\]", local.aws_shared_config)
  )
  resolved_aws_profile = (
    local.requested_aws_profile == null ? null :
    local.requested_profile_exists ? local.requested_aws_profile : "default"
  )

  # Parse aws_region: extract value from pattern `aws_region = "value"`
  aws_region_raw      = try(regex("aws_region\\s*=\\s*\"([^\"]+)\"", local.workspace_file_content)[0], null)
  resolved_aws_region = coalesce(local.aws_region_raw, var.default_aws_region)

  # Parse owner: extract value from pattern `owner = "value"`
  owner_raw      = try(regex("owner\\s*=\\s*\"([^\"]+)\"", local.workspace_file_content)[0], null)
  resolved_owner = coalesce(local.owner_raw, var.default_owner)

  # Parse states: extract list from pattern `states = ["a", "b", "c"]`
  # First strip comment lines (# or ##), then extract the list content
  workspace_file_no_comments = join("\n", [
    for line in split("\n", local.workspace_file_content) :
    line if !can(regex("^\\s*#", line))
  ])
  states_raw = try(regex("states\\s*=\\s*\\[([^\\]]*)]", replace(local.workspace_file_no_comments, "\n", " "))[0], null)

  # Extract individual quoted strings from the captured content
  # Returns null if states_raw is null or if no items found
  states_parsed = local.states_raw != null ? (
    length(regexall("\"([^\"]+)\"", local.states_raw)) > 0 ? [
      for item in regexall("\"([^\"]+)\"", local.states_raw) : item[0]
    ] : null
  ) : null

  # Use parsed states if available, otherwise fall back to defaults
  # Can't use coalesce() with lists, so use conditional instead
  resolved_states = local.states_parsed != null ? local.states_parsed : var.default_states
}
