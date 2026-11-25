# Scheduled EBS snapshots for persistent volumes via Data Lifecycle Manager.
#
# The volumes are pinned to a stable AZ (compute sources their AZ from the subnet,
# not the instance) so a routine instance replacement no longer wipes them. But a
# volume can still be replaced by a genuine spec change (size/type), an AZ topology
# change, or an accidental taint - and these hold checkpoint data with no other
# copy. Daily snapshots make that data recoverable.
#
# Targets volumes by the tags every requested volume carries (Snapshot=daily +
# this deployment's Namespace), so it never touches volumes from other modules or
# deployments.

resource "aws_iam_role" "dlm" {
  count = length(local.volumes) > 0 ? 1 : 0

  name = "ebs-snapshots-${var.namespace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count = length(local.volumes) > 0 ? 1 : 0

  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ebs" {
  count = length(local.volumes) > 0 ? 1 : 0

  # DLM rejects parentheses/periods in the description (allows [0-9A-Za-z _-]).
  description        = "Daily snapshots of persistent EBS volumes - ${var.namespace}"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Snapshot  = "daily"
      Namespace = var.namespace
    }

    schedule {
      name = "daily-7d-retention"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["04:00"]
      }

      retain_rule {
        count = 7
      }

      # Copy the volume's tags (MountPath, Class, Tenant, ...) onto each snapshot
      # so a restore can identify which volume/mount it belongs to.
      copy_tags = true

      # Tag the snapshots themselves for cost attribution and cleanup.
      tags_to_add = {
        Namespace = var.namespace
        ManagedBy = "dlm"
      }
    }
  }
}
