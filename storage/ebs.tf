# EBS Volumes (dependency inversion pattern)
# Other modules (compute) emit volume_requests carrying instance ID + AZ;
# storage creates both the volume and the attachment.
#
# Owning the attachment here breaks what would otherwise be a module cycle:
#   compute(instance) -> storage(volume needs instance.az) -> compute(attachment needs volume.id)
# Now the dataflow is one-way: compute -> storage.

locals {
  volumes = {
    for req in var.volume_requests :
    req.purpose => req
  }
}

resource "aws_ebs_volume" "requested" {
  for_each = local.volumes

  availability_zone = each.value.availability_zone
  size              = each.value.size
  type              = each.value.type
  iops              = each.value.iops
  throughput        = each.value.throughput
  encrypted         = each.value.encrypted
  kms_key_id        = each.value.kms_key_id

  tags = merge(
    {
      Name      = "${each.value.purpose}-${var.namespace}"
      Purpose   = each.value.purpose
      Namespace = var.namespace
    },
    each.value.description != "" ? { Description = each.value.description } : {},
    each.value.tags
  )

  # Persistent storage - decoupled from instance lifecycle.
  # If a future change wants to recreate the volume (size/type), Terraform should
  # create the new one before tearing down the old to keep the data path intact.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_volume_attachment" "requested" {
  for_each = local.volumes

  device_name = each.value.device_name
  volume_id   = aws_ebs_volume.requested[each.key].id
  instance_id = each.value.instance_id

  # Don't try to detach on destroy. The instance termination already detaches
  # the volume - making Terraform also detach causes "VolumeInUse" races on
  # instance replacement. With skip_destroy the attachment resource is dropped
  # from state cleanly; the volume itself persists (no delete_on_termination).
  skip_destroy = true
}
