output "bucket_requests" {
  description = "S3 bucket request for archive storage (dependency inversion to storage module)."
  value = [
    {
      purpose            = "archivist"
      description        = "Versioned platformer source archives produced by the archivist module"
      versioning_enabled = true
      lifecycle_days     = 365
      access_logging     = false
      # Upload the archive immediately after the bucket is created.
      # upload_trigger carries null_resource.archive.id so storage's upload
      # null_resource re-runs whenever the archive is rebuilt, and inherits
      # the resource dependency - ensuring the file exists before upload.
      on_create_command = var.bucket_name != "" ? "AWS_PROFILE=${var.aws_profile} AWS_REGION=${var.aws_region} aws s3 cp ${local.archive_path} s3://${var.bucket_name}/${local.s3_key}" : null
      upload_trigger    = var.bucket_name != "" ? null_resource.archive.id : null
    }
  ]
}

output "repository_requests" {
  description = "CodeCommit repository request for git-based archive storage (dependency inversion to storage module)."
  value = var.repo_name != "" ? [
    {
      purpose     = "archivist"
      description = "Git-based archive of scrubbed platformer codebase for GitOps workflows"
      # Commit the archive to CodeCommit after each build.
      # commit_trigger carries null_resource.archive.id so storage's commit
      # null_resource re-runs whenever the archive is rebuilt.
      on_create_command = "bash ${path.module}/scripts/git-commit.sh ${local.archive_path} ${var.repo_name} ${var.aws_profile} ${var.aws_region}"
      commit_trigger    = null_resource.archive.id
    }
  ] : []
}

output "artifact_requests" {
  description = "Artifact registry entries for the portal module (dependency inversion). Each entry describes a build artifact produced by this module."
  value       = concat(local.artifact_requests, local.git_artifact_requests)
}

output "archive_path" {
  description = "Absolute path of the most-recently-built archive on the local filesystem."
  value       = local.archive_path
}
