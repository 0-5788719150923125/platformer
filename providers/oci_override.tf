# Adds the OCI provider to the root's required_providers (providers.tf).
# Linked into the root as provider_oci_override.tf by scripts/providers.sh.
# Override files merge required_providers entry by entry, which is how an
# optional provider joins without editing providers.tf.

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
  }
}
