# Optional Providers

Terraform sets up every provider the configuration mentions, even for modules
with `count = 0`, so a provider that's merely available would force every user
to hold its credentials. Platformer composes providers per workspace instead,
before Terraform runs (see `next/fully-connected.md`).

Each optional provider has two files here:

- `<name>.tf` - its provider block(s), plus anything that only exists with it
  (AWS: the account/region lookups and the one-cloud products; OCI: adoption
  imports; Port: the portal module).
- `<name>_override.tf` - adds it to the root's `required_providers` and points
  core's defaulted locals at what it provides. Override files merge entry by
  entry, which is how an optional provider joins without editing `providers.tf`.

A workspace declares them in `terraform.tfvars.<workspace>`: `aws_profile`,
`oci_profile`, `port_enabled = true`. `scripts/providers.sh` links the declared
ones into the root as `provider_<name>*.tf`, and wires each service's adapter
(`<service>/<name>/`): adapters with a `wiring.tf.tmpl` (AWS) are linked as-is,
others get the standard `config`/`context` call. The root `optional_providers`
output fails the plan when the wiring doesn't match the declaration.

Rules that keep this safe:

- Core reads an optional provider's modules only through locals, one per value,
  with a default in core and an override here. Referencing a whole module ties
  all its outputs together and closes request round-trips into cycles.
- `scripts/providers.sh` refuses to unwire a provider while the workspace still
  has resources under it. Adapters inherit default providers, and an unwired
  default provider with resources in state can plan to destroy them; emptying the
  workspace first is the only way out of a provider.
