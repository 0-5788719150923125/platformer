# State Fragment Management
# Loads state fragment YAML files and creates Port entities

# Read every available state fragment (user states_paths + states/), as
# resolved by the config module. Keyed by "<name>.yaml".
data "local_file" "state_fragments" {
  for_each = { for name, p in var.state_files : "${name}.yaml" => p }
  filename = each.value
}

# Get git repository URL for GitHub links
data "external" "state_git_info" {
  program = ["bash", "-c", <<-EOF
    echo "{\"repo_url\":\"$(git config --get remote.origin.url)\",\"branch\":\"$(git rev-parse --abbrev-ref HEAD)\"}"
  EOF
  ]
  working_dir = path.root
}

locals {
  # Convert git SSH URL to HTTPS format for display
  state_repo_url = replace(
    replace(data.external.state_git_info.result.repo_url, "git@github.com:", "https://github.com/"),
    ".git",
    ""
  )

  state_branch_name = data.external.state_git_info.result.branch

  # Fragments under the repo's states/ get a GitHub link; ones from user
  # states_paths live outside the repo and have none.
  repo_states_dir = "${abspath("${path.root}/states")}/"

  # Parse state fragments and extract metadata
  state_fragments_parsed = {
    for key, file in data.local_file.state_fragments : key => {
      filename = trimsuffix(key, ".yaml")
      # Wrap YAML content in markdown code fences for proper display in Port
      content = "```yaml\n${file.content}\n```"
      # Check if this state is actively used in the deployment
      enabled = contains(var.states, trimsuffix(key, ".yaml"))
      # Try to parse services from YAML
      services = try(
        [for service_key, service_value in yamldecode(file.content).services : service_key],
        []
      )
      # GitHub URL to view the file
      github_url = startswith(abspath(file.filename), local.repo_states_dir) ? "${local.state_repo_url}/blob/${local.state_branch_name}/platformer/states/${key}" : ""
    }
  }
}

# Create Port entities for state fragments
resource "port_entity" "state_fragment" {
  for_each = local.state_fragments_parsed

  identifier = "${each.value.filename}-${var.namespace}"
  title      = each.value.filename
  blueprint  = local.bp_state_fragment
  teams      = var.teams

  properties = {
    string_props = {
      yamlContent = each.value.content
      filename    = each.value.filename
      namespace   = var.subspace
      workspace   = var.namespace
      githubUrl   = each.value.github_url
      enabled     = tostring(each.value.enabled)
    }
    array_props = {
      string_items = {
        services = each.value.services
      }
    }
  }

  depends_on = [port_blueprint.state_fragment]
}
