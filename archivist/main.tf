# Archivist Module
# Produces a scrubbed, versioned tarball of the platformer codebase on every apply.
# Sensitive strings (account IDs, internal domains, bucket names, account targets)
# are replaced via scrub.sed before packaging. Output lands in archivist/build/,
# which is git-ignored (see archivist/.gitignore).
#
# Dependency graph:
#   archivist (git archive + scrub) --> portal (artifact_requests --> artifact entities)

# ============================================================================
# Git Info
# ============================================================================

# Capture the current commit SHA and timestamp at plan time.
# These drive both the null_resource trigger and the deterministic artifact path.
data "external" "git_info" {
  program = ["bash", "-c", <<-EOF
    echo "{\"sha\":\"$(git rev-parse --short HEAD)\",\"date\":\"$(git log -1 --format=%cd --date=format:%Y-%m-%d HEAD)\",\"timestamp\":\"$(git log -1 --format=%cI HEAD)\"}"
  EOF
  ]
  working_dir = path.root
}

# ============================================================================
# Archive Generation
# ============================================================================

locals {
  archive_name = "platformer-${data.external.git_info.result.date}-${data.external.git_info.result.sha}.tar.gz"
  archive_path = "${path.module}/build/${local.archive_name}"
  s3_key       = local.archive_name
  s3_url       = var.bucket_name != "" ? "https://s3.console.aws.amazon.com/s3/object/${var.bucket_name}?region=${var.aws_region}&prefix=${local.s3_key}" : ""

  # CodeCommit console URL for the artifact registry
  codecommit_url = var.repo_name != "" ? "https://${var.aws_region}.console.aws.amazon.com/codesuite/codecommit/repositories/${var.repo_name}/browse?region=${var.aws_region}" : ""

  # Artifact registry entries - consumed by the portal module via dependency inversion.
  # The path is deterministic (based on git SHA), so these locals are correct even
  # before the null_resource provisioner has run on the very first apply.
  artifact_requests = [
    {
      name       = "platformer"
      version    = data.external.git_info.result.sha
      type       = "archive"
      path       = local.archive_path
      source     = "archivist"
      created_at = data.external.git_info.result.timestamp
      url        = local.s3_url
    }
  ]

  # Git-repository artifact entry (conditional on repo_name being set)
  git_artifact_requests = var.repo_name != "" ? [
    {
      name       = "platformer"
      version    = data.external.git_info.result.sha
      type       = "git-repository"
      path       = var.repo_name
      source     = "archivist"
      created_at = data.external.git_info.result.timestamp
      url        = local.codecommit_url
    }
  ] : []
}

resource "null_resource" "upload_access_report" {
  triggers = {
    # report_ready changes whenever the access report is rewritten - implicit ordering dep on local_file.access_report
    report_ready = var.report_ready
    # bucket_name is a storage resource attribute - implicit ordering dep on aws_s3_bucket["access-report"]
    bucket_name = var.report_bucket_name
  }

  provisioner "local-exec" {
    command = var.report_bucket_name != "" ? "AWS_PROFILE=${var.aws_profile} AWS_REGION=${var.aws_region} aws s3 cp ${var.report_path} s3://${var.report_bucket_name}/${basename(var.report_path)}" : "echo 'access report upload skipped: bucket not configured'"
  }
}

resource "null_resource" "archive" {
  triggers = {
    # Re-build when the commit changes, scrub rules are updated, or resolved states change.
    git_sha     = data.external.git_info.result.sha
    scrub_hash  = filesha256("${path.module}/scrub.sed")
    states_hash = sha256(jsonencode(var.states))
  }

  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/archivist.sh"
    working_dir = path.root
    environment = {
      # Comma-separated list of resolved state fragment names.
      # The script removes any states/*.yaml not in this list.
      ARCHIVIST_STATES = join(",", var.states)
    }
  }
}
