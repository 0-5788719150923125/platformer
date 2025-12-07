# Auto-Docs

Automatic documentation generator for Platformer modules - parses `variables.tf` files and generates `SCHEMA.md` with YAML examples.

## ⚠️ Status: Extremely Alpha

This module is **highly experimental** and comes with several caveats:

- **Fragile**: Complex AWK parsing logic that breaks easily with edge cases
- **Maintenance burden**: Bash + AWK makes debugging and iteration painful
- **Should be rewritten**: This belongs in Python with proper HCL parsing (e.g., `python-hcl2`)
- **No guarantees**: May produce incorrect output for unusual variable structures

**Why it exists**: Rapid prototyping to validate the concept. It works well enough for our current needs, but shouldn't be considered production-ready tooling.

## What It Does

Generates `SCHEMA.md` from all `variables.tf` files across modules, showing:

- YAML structure for state fragments (from `config` variables)
- Inline comments from HCL (e.g., "Volume size override")
- Default values extracted from `optional()` declarations
- Module interface variables with simplified types

**Example output:**
```yaml
services:
  compute:
    classes:  # map
      <key>:
        ami_filter: string  # AWS AMI name filter (e.g., "Windows_Server-2022-*")
        volume_size: number  # Volume size override
        count: number  # Number of instances per tenant (default: 1)
```

## How It Works

1. External data source calls `scripts/generate-docs.sh`
2. Script uses AWK to parse HCL variable definitions
3. Extracts nested `object()` structures and inline comments
4. Generates YAML examples with proper indentation
5. Writes result to `SCHEMA.md` via `local_file` resource

## Usage

Automatically invoked on every `terraform plan/apply` - generates `platformer/SCHEMA.md` deterministically.

## Known Limitations

- Only parses `config` variables (not arbitrary variable structures)
- AWK regex patterns are brittle and hard to debug
- Complex nested structures may render incorrectly
- No validation of generated YAML syntax
- Inline comments must follow specific patterns to be captured

## Future: Rewrite in Python

A proper implementation would use:
- `python-hcl2` or `pyhcl` for robust HCL parsing
- Proper AST traversal instead of regex
- Unit tests for edge cases
- YAML library for guaranteed valid output
- Better error handling and debugging
