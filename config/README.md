# Config

Configuration resolution via YAML state fragments. Loads, deep-merges, and extracts service configurations.

## Purpose

Centralizes configuration logic. Load the same YAML state fragments used by CI/CD for local development. Multiple states deep-merge with later states overriding earlier ones.

## How It Works

1. Takes list of state fragment names from `terraform.tfvars`
2. Calls `scripts/merge-states.sh` to load and merge YAML files
3. Extracts `services` key from merged configuration
4. Returns resolved service configs to modules

## Benefits

- **Single Source of Truth** - Same state files for CI/CD and local dev
- **Clean Abstraction** - Complex merging logic hidden from root module
- **Easy Testing** - Module tests in isolation
- **Clear Interface** - Well-defined inputs/outputs via dependency inversion
