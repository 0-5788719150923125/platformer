# States

Reusable configuration fragments referenced in `top.yaml`. Inspired by Salt's state system.

## Structure

Each YAML file may contain:
- `matrix`: CI/CD matrix configuration (for GitHub Actions parallel deployments)
  - `regions`: Array of AWS regions to deploy to
  - Note: Accounts are auto-discovered via AWS Organizations API
- `services`: Service configurations

## Usage

Reference by name in `top.yaml`:

```yaml
targets:
  # Simple pattern matching
  '*-platform-dev':
    - regions-east
    - configuration-management

  # Compound matching with OR (matches either pattern)
  '*uat* or org-staging-*':
    - regions-east
    - configuration-management-monthly

  # Compound matching with AND (matches both patterns)
  '*dev* and *platform*':
    - regions-most
    - configuration-management-hourly
```

**Supported Pattern Types:**
- Simple glob patterns: `'*dev*'`, `'prefix-*'`, `'*-suffix'`
- OR operators: `'pattern1 or pattern2'` - matches either
- AND operators: `'pattern1 and pattern2'` - matches both
- All matching is case-insensitive

## Merging

States apply left-to-right:
- **matrix.regions**: Concatenate and deduplicate arrays
- **services**: Deep merge objects (later overrides earlier)

Example override:
```yaml
# top.yaml
targets:
  'prod-account':
    - configuration-management          # defaults
    - configuration-management-hourly   # overrides to hourly rotation
```

## Storing States Outside This Repo

Fragments don't have to live in `states/`. Set `states_paths` in `terraform.tfvars` (or a workspace's `terraform.tfvars.<workspace>`) to a list of extra directories to search:

```hcl
states = ["my-arcbot", "regions-east"]
states_paths = [
  "~/configs/platformer",       # "~" expands to your home directory
  "/srv/platformer/states",     # absolute paths are used as-is
  "../my-org-states",           # relative paths resolve against the repo root
]
```

Search order is your `states_paths` entries in the order listed, then `states/`, then `tests/states/`. Each name in `states` loads from the first directory that has `<name>.yaml`, so on a name conflict your copy wins over the repo's. Names still follow the usual rule (lowercase letters, digits, hyphens).

Notes:
- Every listed directory must exist, or plan fails with `states dir(s) not found`. This stops a typo from silently falling through to a same-named fragment in `states/`.
- A workspace file's `states_paths` replaces the base list rather than adding to it, same as `states`. `states_paths = []` in a workspace file turns the base list off.
- The archivist bundle includes the fragments you selected from external paths, copied into its `states/` (replacing a same-named repo fragment) and scrubbed like everything else. Editing an external fragment rebuilds the archive even without a new commit.
- The portal's state catalog lists every fragment in your `states_paths` plus `states/` (not `tests/states/`). External fragments have no GitHub link.
- Tests: `config/tests/states_paths.tftest.hcl`, `workspaces/tests/states_paths.tftest.hcl`, `archivist/tests/states.tftest.hcl`, `tests/states_paths.tftest.hcl`.

## Creating States

1. Create `states/my-state.yaml`
2. Add regions/services configuration
3. Reference in `top.yaml`
4. Test with `scripts/generate-matrix.sh`
