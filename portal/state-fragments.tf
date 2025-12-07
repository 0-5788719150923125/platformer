# State Fragment Management
# Loads state fragment YAML files and creates Port entities

# Read all state fragment files from states/ directory
data "local_file" "state_fragments" {
  for_each = fileset(path.root, "states/*.yaml")
  filename = "${path.root}/${each.value}"
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

  # Parse state fragments and extract metadata
  state_fragments_parsed = {
    for path, file in data.local_file.state_fragments : basename(path) => {
      filename = replace(basename(path), ".yaml", "")
      # Wrap YAML content in markdown code fences for proper display in Port
      content = "```yaml\n${file.content}\n```"
      # Check if this state is actively used in the deployment
      enabled = contains(var.states, replace(basename(path), ".yaml", ""))
      # Try to parse services from YAML
      services = try(
        [for service_key, service_value in yamldecode(file.content).services : service_key],
        []
      )
      # GitHub URL to view the file
      github_url = "${local.state_repo_url}/blob/${local.state_branch_name}/platformer/states/${basename(path)}"
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
