# Tenants

Centralized tenant registry and validation.

## Purpose

Single source of truth for valid tenant codes. Consumer modules validate their tenant lists against this registry. Invalid tenants are rejected at plan time with clear error messages.

## Registry

All tenants defined in `tenants.yaml` with active/inactive status. Currently 69+ tenants, sorted alphabetically.

Consumer modules reference tenants by code. The tenants module validates these references and fails fast on typos or inactive tenants.

## Future Evolution

The hardcoded YAML registry will eventually integrate with ServiceNow API. The output interface will remain unchanged for transparent migration.
