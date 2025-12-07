# Documentation Management
# Loads markdown files from multiple sources and creates Port entities

# Read main README.md for page widget
data "local_file" "main_readme" {
  filename = "${path.root}/README.md"
}

# Get AWS caller identity for workspace ownership info
data "aws_caller_identity" "current" {}

# Get git repository information
data "external" "git_info" {
  program = ["bash", "-c", <<-EOF
    echo "{\"repo_url\":\"$(git config --get remote.origin.url)\",\"branch\":\"$(git rev-parse --abbrev-ref HEAD)\"}"
  EOF
  ]
  working_dir = path.root
}

# Get all commits from branch divergence point to HEAD
data "external" "git_commits" {
  program = ["bash", "-c", <<-EOF
    # Find merge base with master (where branch diverged)
    merge_base=$(git merge-base master HEAD 2>/dev/null || echo "HEAD")
    # Get all commits from merge base to HEAD with absolute timestamp for sorting
    commits=$(git log $merge_base..HEAD --pretty=format:'%h|%s|%an|%cI' | jq -R -s -c 'split("\n") | map(select(length > 0))')
    # External data source requires all values to be strings, so we JSON-encode the array as a string
    echo "{\"commits\":$(echo "$commits" | jq -R .)}"
  EOF
  ]
  working_dir = path.root
}

locals {
  # Extract first section from README (everything before first ##)
  readme_first_section = trimspace(split("\n##", data.local_file.main_readme.content)[0])

  # Extract email from ARN (format: arn:aws:sts::account:assumed-role/role/email)
  caller_email = try(
    element(split("/", data.aws_caller_identity.current.arn), length(split("/", data.aws_caller_identity.current.arn)) - 1),
    "unknown"
  )

  # Convert git SSH URL to HTTPS format for display
  repo_url = replace(
    replace(data.external.git_info.result.repo_url, "git@github.com:", "https://github.com/"),
    ".git",
    ""
  )

  branch_name = data.external.git_info.result.branch

  # Construct full GitHub URL with branch and directory
  full_source_url = "${local.repo_url}/tree/${local.branch_name}/platformer"

  # Parse git commits into structured data
  # Double decode because external data source returns JSON-encoded string
  # Key by commit hash to prevent state churn when new commits are added
  commits_raw = jsondecode(data.external.git_commits.result.commits)
  commits_formatted = {
    for commit in local.commits_raw : split("|", commit)[0] => {
      hash               = split("|", commit)[0]
      full_title         = split("|", commit)[1]
      author             = split("|", commit)[2]
      absolute_timestamp = split("|", commit)[3]
      # Extract key from commit title (e.g., "PROJ-5103: message" -> "PROJ-5103")
      key = try(regex("^([A-Z]+-[0-9]+)", split("|", commit)[1])[0], "")
      # Strip key prefix from title if present
      title      = try(regex("^[A-Z]+-[0-9]+:?\\s*(.*)", split("|", commit)[1])[0], split("|", commit)[1])
      commit_url = "${local.repo_url}/commit/${split("|", commit)[0]}"
    }
  }

  # Create markdown content with custom footer (without commits table)
  # Using indent() to ensure proper YAML formatting
  readme_widget_content = indent(10, <<-EOT
${local.readme_first_section}

---

**Source:** [${local.full_source_url}](${local.full_source_url})

**Deployer**: ${local.caller_email}

[**States**](https://app.us.getport.io/my-states-${var.namespace}) | [**Artifacts**](https://app.us.getport.io/my-artifacts-${var.namespace})
EOT
  )
}

# Read markdown files from next/ directory
data "local_file" "docs_next" {
  for_each = fileset("${path.root}", "next/*.md")
  filename = "${path.root}/${each.value}"
}

# Read markdown files from learn/ directory
data "local_file" "docs_learn" {
  for_each = fileset("${path.root}", "learn/*.md")
  filename = "${path.root}/${each.value}"
}

# Read markdown files from present/ directory
data "local_file" "docs_present" {
  for_each = fileset("${path.root}", "present/*.md")
  filename = "${path.root}/${each.value}"
}

# Read markdown files from near/ directory
data "local_file" "docs_near" {
  for_each = fileset("${path.root}", "near/*.md")
  filename = "${path.root}/${each.value}"
}

# Read markdown files from behind/ directory
data "local_file" "docs_behind" {
  for_each = fileset("${path.root}", "behind/*.md")
  filename = "${path.root}/${each.value}"
}

# Read README.md files from module directories
data "local_file" "docs_readme" {
  for_each = fileset("${path.root}", "*/README.md")
  filename = "${path.root}/${each.value}"
}

# Read SCHEMA.md if it exists
data "local_file" "docs_schema" {
  for_each = fileexists("${path.root}/SCHEMA.md") ? toset(["SCHEMA.md"]) : toset([])
  filename = "${path.root}/${each.value}"
}

locals {
  # Merge all documentation sources with their categories
  all_docs = merge(
    # next/*.md files tagged as "next"
    {
      for file, data in data.local_file.docs_next :
      file => {
        content  = data.content
        filename = file
        tag      = "next"
      }
    },
    # learn/*.md files tagged as "learning"
    {
      for file, data in data.local_file.docs_learn :
      file => {
        content  = data.content
        filename = file
        tag      = "learning"
      }
    },
    # present/*.md files tagged as "presentation"
    {
      for file, data in data.local_file.docs_present :
      file => {
        content  = data.content
        filename = file
        tag      = "presentation"
      }
    },
    # near/*.md files tagged as "near"
    {
      for file, data in data.local_file.docs_near :
      file => {
        content  = data.content
        filename = file
        tag      = "near"
      }
    },
    # behind/*.md files tagged as "behind"
    {
      for file, data in data.local_file.docs_behind :
      file => {
        content  = data.content
        filename = file
        tag      = "behind"
      }
    },
    # */README.md files tagged as "module"
    {
      for file, data in data.local_file.docs_readme :
      file => {
        content  = data.content
        filename = file
        tag      = "module"
      }
    },
    # SCHEMA.md tagged as "spec"
    {
      for file, data in data.local_file.docs_schema :
      file => {
        content  = data.content
        filename = file
        tag      = "spec"
      }
    }
  )

  # Extract title from first H1 or H2 heading or use filename
  # For numbered files (e.g., 01-intro.md), prepend the number to the heading text
  doc_titles = {
    for file, doc in local.all_docs :
    file => (
      length(regexall("(?m)^#{1,2}\\s+(.+)$", doc.content)) > 0
      ? (
        # Check if filename starts with a number pattern (e.g., "01-", "11-")
        length(regexall("^(\\d+)-", basename(file))) > 0
        ? "${regex("^(\\d+)-", basename(file))[0]} ${regex("(?m)^#{1,2}\\s+(.+)$", doc.content)[0]}"
        : regex("(?m)^#{1,2}\\s+(.+)$", doc.content)[0]
      )
      : title(replace(replace(basename(file), ".md", ""), "-", " "))
    )
  }

  # Extract summary from first paragraph (first non-heading, non-empty line)
  doc_summaries = {
    for file, doc in local.all_docs :
    file => try(
      trimspace(regex("(?m)^[^#\\n][^\n]+", doc.content)),
      "No summary available"
    )
  }

  # Categorize based on source directory
  doc_categories = {
    for file, doc in local.all_docs :
    file => doc.tag
  }

  # Generate tags based on source directory
  doc_tags = {
    for file, doc in local.all_docs :
    file => ["documentation", "platformer", doc.tag]
  }
}

# Process markdown content to replace relative links with Port entity URLs or GitHub URLs
# Images are base64-encoded for inline display in Port
# Documentation files → Port URLs: [text](path.md) → [text](https://app.us.getport.io/documentationEntity?identifier=...)
# Source code files → GitHub URLs: [text](file.tf) → [text](https://github.com/org/repo/tree/branch/platformer/file.tf)
data "external" "processed_docs" {
  for_each = local.all_docs

  program = ["bash", "${path.module}/scripts/process-markdown-links.sh"]

  query = {
    content   = each.value.content
    namespace = var.namespace
    # Pass all file paths so the script knows which files are uploaded to Port
    file_map = jsonencode({ for file in keys(local.all_docs) : file => true })
    # Pass GitHub info for converting non-documentation links
    repo_url    = local.repo_url
    branch      = local.branch_name
    source_file = each.key
  }
}

# Create Port entity for each documentation file
resource "port_entity" "documentation" {
  for_each = local.is_subspace ? {} : local.all_docs

  # Sanitize identifier: remove any non-alphanumeric/non-hyphen/non-underscore characters
  # Port identifiers allow: letters, numbers, @ _ . + : \ / = -
  # Keep only: alphanumeric + hyphen + underscore + dot
  identifier = "${lower(replace(replace(each.key, ".md", ""), "/[^a-zA-Z0-9._-]/", ""))}-${var.namespace}"
  title      = local.doc_titles[each.key]
  blueprint  = local.bp_documentation
  teams      = var.teams

  properties = {
    string_props = {
      # Use processed content with converted links
      content   = sensitive(data.external.processed_docs[each.key].result.processed_content)
      category  = local.doc_categories[each.key]
      summary   = local.doc_summaries[each.key]
      filename  = each.key
      namespace = var.namespace
      status    = "Published"
    }
    array_props = {
      string_items = {
        tags = local.doc_tags[each.key]
      }
    }
  }

  depends_on = [port_blueprint.documentation]
}

# Create Port entity for each git commit
resource "port_entity" "git_commit" {
  for_each = local.is_subspace ? {} : local.commits_formatted

  identifier = "commit-${each.value.hash}-${var.namespace}"
  title      = each.value.key != "" ? each.value.key : each.value.hash
  blueprint  = local.bp_git_commit
  teams      = var.teams

  properties = {
    string_props = {
      hash              = each.value.hash
      fullTitle         = each.value.full_title
      title             = each.value.title
      key               = each.value.key
      author            = each.value.author
      absoluteTimestamp = each.value.absolute_timestamp
      commitUrl         = each.value.commit_url
      namespace         = var.namespace
    }
  }

  depends_on = [port_blueprint.git_commit]
}

# Create Port entity for each tenant with entitlements
resource "port_entity" "tenant_entitlement" {
  for_each = var.tenant_entitlements

  identifier = "tenant-${each.key}-${var.namespace}"
  title      = upper(each.key)
  blueprint  = local.bp_tenant_entitlement
  teams      = var.teams

  properties = {
    string_props = {
      tenantCode = each.key
      namespace  = var.namespace
    }
    array_props = {
      string_items = {
        entitlements = each.value
      }
    }
  }

  depends_on = [port_blueprint.tenant_entitlement]
}
