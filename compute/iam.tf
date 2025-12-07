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
}
