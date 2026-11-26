# Workspaces

Enables workspace-specific variable overrides using `terraform.tfvars.{workspace}` files.

## Problem

Terraform workspaces provide state isolation but don't natively support workspace-specific variable files. You can't have different AWS profiles or regions per workspace without manually editing files.

## Solution

Detects the current workspace name, looks for a corresponding `terraform.tfvars.{workspace}` file, parses workspace-specific values, and falls back to base values when the file doesn't exist.

Supports overrides for: `aws_profile`, `aws_region`, `owner`, `fragments`, `fragment_paths`

`fragment_paths` lists extra directories to search for fragments, ahead of `fragments/` (see [`fragments/README.md`](../fragments/README.md#storing-fragments-outside-this-repo)). Like every other key it replaces the base value, so `fragment_paths = []` in a workspace file clears the base list.

Tests (`tests/fragment_paths.tftest.hcl`) point the optional `workspace_file_path` variable at fixtures in `tests/fixtures/` instead of a real `terraform.tfvars.<workspace>`.

## Design

Uses native Terraform functions (`file()`, `regex()`, `try()`) for plan-time evaluation. Partial overrides supported - workspace file can override just profile while inheriting region and fragments from base.

The default workspace always uses base `terraform.tfvars`. Named workspaces use their specific file if it exists, otherwise fall back to base.

## Limitations

Simple regex-based parsing. Only supports strings and string lists. Complex HCL syntax may fail. Keep workspace files simple with literal values only.
