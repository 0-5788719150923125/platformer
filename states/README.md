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

## Creating States

1. Create `states/my-state.yaml`
2. Add regions/services configuration
3. Reference in `top.yaml`
4. Test with `scripts/generate-matrix.sh`
