# IAM for EC2 Instances
# Only created when classes declare applications (dependency inversion)
# IAM resources are managed by the access module; this file only determines whether applications exist

locals {
  # Check if any entitled classes have applications defined,
  # OR if standalone/wildcard applications exist that may target compute instances
  has_applications = anytrue([
    for class_name, class_config in var.config :
    length(lookup(class_config, "applications", [])) > 0
    if length(lookup(var.tenants_by_class, class_name, [])) > 0
  ]) || length(var.application_requests) > 0

  # Whether any entitled class declares persistent storage volumes.
  # Drives the storage-volume-discovery inline policy so the storage-mount
  # ansible playbook can find volumes by their MountPath tag at runtime.
  has_volumes = anytrue([
    for class_name, class_config in var.config :
    length(coalesce(class_config.volumes, [])) > 0
    if length(lookup(var.tenants_by_class, class_name, [])) > 0
  ])
}
