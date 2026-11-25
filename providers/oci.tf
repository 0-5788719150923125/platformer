# Oracle Cloud (OCI)
#
# Linked into the root as provider_oci.tf by scripts/providers.sh, only in
# workspaces whose terraform.tfvars.<workspace> sets oci_profile. Everywhere
# else this file doesn't exist as far as Terraform is concerned, so the OCI
# provider is never downloaded or set up. Adapters (e.g. compute/oci/) inherit
# this default provider implicitly.

provider "oci" {
  config_file_profile = module.workspaces.oci_profile
  region              = module.workspaces.oci_region
}

# Adoption: instances listed under a class's `adopt` already exist. They are
# imported, never created, and the plan shows them as "will be imported".
# Once they're in state, these imports are no-ops.
import {
  for_each = local.compute_enabled ? lookup(module.compute[0].adoptions, "oci", {}) : {}
  to       = module.compute[0].module.oci.oci_core_instance.this[each.key]
  id       = each.value
}
