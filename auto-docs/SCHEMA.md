# Platformer Module Schema

Auto-generated from variables.tf and outputs.tf files. Do not edit manually.

This document shows the YAML structure for state fragments in `states/` directory.

## Supported Modules

- [root](#module-root)


## Module: root

Path: [`.`](.)

Automatic documentation generator for Platformer modules - parses `variables.tf` files and generates `SCHEMA.md` with YAML examples.

### Arguments

This module supports the following arguments:

| Variable | Type | Required | Description | Ref |
|----------|------|----------|-------------|-----|
| `project_root` | `string` | No | Path to project root directory | [./variables.tf:4](./variables.tf#L4) |
| `output_file` | `string` | No | Path to output schema file (relative to project root) | [./variables.tf:10](./variables.tf#L10) |
| `readme_file` | `string` | No | Path to README file to update (relative to project root) | [./variables.tf:16](./variables.tf#L16) |

### Attributes

This module exports the following attributes:

| Output | Description | Ref |
|--------|-------------|-----|
| `schema_file_path` | Path to generated schema file | [./outputs.tf:3](./outputs.tf#L3) |
| `modules_documented` | Number of modules documented | [./outputs.tf:8](./outputs.tf#L8) |
| `content_hash` | MD5 hash of generated content (for change detection) | [./outputs.tf:13](./outputs.tf#L13) |
| `readme_updated` | Status of README update | [./outputs.tf:18](./outputs.tf#L18) |
| `readme_hash` | MD5 hash of updated README (for change detection) | [./outputs.tf:23](./outputs.tf#L23) |
