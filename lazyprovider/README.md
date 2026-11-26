# lazyprovider

Platformer declares its clouds through `platformer.local/lazyprovider/<cloud>`
providers: small proxies that stand in front of the real providers
(`hashicorp/aws`, `oracle/oci`, `port-labs/port-labs`) and set them up only in
workspaces that enable them. Every cloud stays part of one configuration and one graph, and a
workspace never needs credentials for a cloud it doesn't use.

## Why

Terraform sets up every provider the configuration mentions before planning,
even when nothing will use it (modules with `count = 0` still name their
provider). Setting up usually means logging in or finding credentials, so a
configuration that supports several clouds would force every workspace to hold
credentials for all of them. Terraform has no switch for this: `for_each` on
provider blocks is still reserved for a future version (1.17.2).

## How it works

The proxy speaks Terraform's plugin protocol (versions 5 and 6, whichever the
real provider speaks) and relays every call to the real provider as raw bytes.
It handles three things itself:

- **Schema:** it adds one argument of its own, `enabled`, to the provider block.
- **Validation and setup:** it removes `enabled` before the real provider sees
  any configuration, and decides what to do with setup based on its value.
- **Calls that need a configured provider** (plan, apply, read, import, data
  sources, ephemeral resources): handled according to `enabled`.

| `enabled` | Behavior |
|---|---|
| `true` or unset | The real provider is set up during Terraform's setup call, exactly as without the proxy. Errors appear once, at the provider block. |
| `false` | Never set up. A resource that needs it fails with one short error at that resource. |
| unknown at plan time | Set up on first use. The first failure carries the real provider's error; repeats are one line with its summary. |

Platformer sets `enabled` from the workspace's profiles (`providers.tf`).

The real providers are declared in `upstreams.tf`, right here. This directory
is also a Terraform module with no resources, called from the root's `main.tf`
(Terraform reads only its `.tf` files, Go only its `.go` files), so
`terraform init` installs and verifies the real providers while nothing uses
them directly. The proxy starts its real provider from `.terraform/providers`
in the working directory, or the nearest parent's (so `terraform test` inside a
module uses the root's).

## Build

```sh
scripts/build-providers.sh
terraform init        # or: terraform init -upgrade after rebuilding the same version
```

The script downloads a pinned Go toolchain into `~/.cache/platformer`
(checksum-verified; no system Go needed), runs the unit tests, builds one
binary, and installs it as each supported provider into
`~/.terraform.d/plugins`, which Terraform searches for every working directory.
Run it once per proxy version (`VERSION`). The build is reproducible (the same
source and Go version give the same bytes), so running it again without proxy
changes leaves the lock file valid. After changing the proxy's source without
bumping `VERSION`, `terraform init -upgrade` accepts the new checksum.

## The address

The proxies live at `platformer.local/lazyprovider/<cloud>`, not at a registry
address. `.local` names are for this machine and its network, which is exactly
where these providers come from: Terraform finds them in its local plugin
directory, and nowhere else. A short address like `platformer/aws` would mean
`registry.terraform.io/platformer/aws`, so a checkout that hadn't built the
proxies would ask the public registry for them, and the `platformer` namespace
there belongs to whoever owns that GitHub name. With `.local`, an unbuilt
checkout fails instead (_"could not connect to platformer.local"_, after a few
retries), and nothing can be fetched in place of the build: Terraform only
talks to registries over HTTPS, and no public certificate authority issues
certificates for `.local` names.

## Limits

- Modules must declare the proxy as their provider (`aws = { source =
  "platformer.local/lazyprovider/aws" }`). A module that pins `hashicorp/aws`
  can't receive the proxy ("Provider type mismatch") and, unmapped, would use
  the real provider directly. Platformer uses no third-party modules for its clouds.
- Moving existing state onto the proxy is a one-time
  `terraform state replace-provider registry.terraform.io/hashicorp/aws platformer.local/lazyprovider/aws`.
- A failed setup is reported once per resource that needed it (shortened after
  the first), not once per provider, unless `enabled = true` reports it at setup.
- If the proxy is killed hard (not shut down by Terraform), its real provider
  process can be left running.
