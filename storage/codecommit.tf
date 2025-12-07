# CodeCommit repositories (dependency inversion pattern)
# Other modules define repository requirements via repository_requests variable

locals {
  # Create map of repositories from repository_requests
  # Key format: "{purpose}" (purpose must be unique per validation)
  repositories = {
    for req in var.repository_requests :
    req.purpose => {
      repo_name         = "${req.purpose}-${var.namespace}"
      purpose           = req.purpose
      description       = req.description
      default_branch    = req.default_branch
      on_create_command = req.on_create_command
      commit_trigger    = req.commit_trigger
    }
  }
}

resource "aws_codecommit_repository" "requested" {
  for_each = local.repositories

  repository_name = each.value.repo_name
  description     = each.value.description

  tags = {
    Name        = each.value.repo_name
    Purpose     = each.value.purpose
    Description = each.value.description
    Namespace   = var.namespace
  }

  # Default branch cannot be set on an empty repo - managed by set_default_branch below
  lifecycle {
    ignore_changes = [default_branch]
  }
}

# Post-creation commit (optional, per repository request)
# Runs on_create_command immediately after the repository exists.
# commit_trigger carries an opaque dependency value from the requester (e.g., a
# null_resource.id) so this re-runs whenever the source artifact changes.
resource "null_resource" "post_create_commit" {
  for_each = {
    for k, v in local.repositories : k => v
    if v.on_create_command != null
  }

  triggers = {
    repo_arn       = aws_codecommit_repository.requested[each.key].arn
    commit_trigger = each.value.commit_trigger
  }

  provisioner "local-exec" {
    command = each.value.on_create_command
  }
}

# Set default branch after initial commit (empty repos have no branches)
# Fails gracefully - the branch may not exist yet on first apply
resource "null_resource" "set_default_branch" {
  for_each = {
    for k, v in local.repositories : k => v
    if v.on_create_command != null
  }

  triggers = {
    repo_arn = aws_codecommit_repository.requested[each.key].arn
  }

  provisioner "local-exec" {
    command = <<-EOF
      AWS_PROFILE=${var.aws_profile} AWS_REGION=${var.aws_region} \
        aws codecommit update-default-branch \
          --repository-name ${each.value.repo_name} \
          --default-branch-name ${each.value.default_branch} \
        2>/dev/null || echo "codecommit: default branch not set yet (repo may be empty)"
    EOF
  }

  depends_on = [null_resource.post_create_commit]
}
