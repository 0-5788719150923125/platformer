# Preflight

Reusable dependency validation utilities for checking CLI tool availability.

## Purpose

Fast-fail dependency checking to prevent partial Terraform applies when required external tools are missing. Validation happens automatically at plan time - just declare your dependencies.

## Check Types

**discrete** - Single command must exist in PATH

**any** - At least one command from list must exist (handles alternatives like `docker compose` vs `docker-compose`)

## Design

Modules declare their own dependencies. Preflight centralizes validation logic. Fails during plan phase with clear error messages listing all missing tools.

Current consumers: compute (packer, python3), portal (docker, docker-compose).
