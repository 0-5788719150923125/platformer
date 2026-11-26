# Config

Configuration resolution via YAML fragments. Loads, deep-merges, and extracts service configurations.

## Purpose

Centralizes configuration logic. Load the same YAML fragments used by CI/CD for local development. Multiple fragments deep-merge with later fragments overriding earlier ones.

## How It Works

1. Takes list of fragment names from `terraform.tfvars`
2. Finds each `<name>.yaml` in the first matching dir of `fragment_dirs`. The root module passes the user's `fragment_paths` first, then `fragments/`, then `tests/fragments/`. A missing dir or missing fragment fails the plan with an explicit message.
3. Deep-merges the fragments left-to-right with the `deepmerge` provider (union mode)
4. Extracts `services` and `matrix` from the merged configuration
5. Returns resolved service configs to modules, plus `fragment_files` (where each selected fragment came from) and `available_fragments` (every fragment in `catalog_dirs`, for the portal catalog)

## Benefits

- **Single Source of Truth** - Same state files for CI/CD and local dev
- **Clean Abstraction** - Complex merging logic hidden from root module
- **Easy Testing** - Module tests in isolation
- **Clear Interface** - Well-defined inputs/outputs via dependency inversion
