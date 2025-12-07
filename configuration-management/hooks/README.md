# Universal Hook System

Intelligent pre/post install lifecycle hooks for all managed instances in the Platformer framework.

## Overview

The Universal Hook System provides automated lifecycle hooks for installation and patching operations. Hooks detect services running on instances (Redis, PostgreSQL, etc.) and perform appropriate safety checks **without requiring any tags or configuration**.

## Key Features

- **Universal Application**: Hooks run on ALL instances during patching
- **Service Detection**: Automatically detects installed services (no tags required)
- **No-Op When Absent**: Gracefully skips checks if service not installed
- **Sequential Execution**: Numeric prefixes control execution order
- **Fail-Fast**: Critical failures abort patching pipeline
- **Extensible**: Add new service checks by adding scripts

## Architecture

```
platformer/
├── storage/                   # Creates S3 buckets from bucket_requests
│   └── main.tf               # Dependency inversion: buckets defined elsewhere
└── configuration-management/
    ├── hooks/
    │   ├── linux/
    │   │   ├── pre/               # Hook scripts (run BEFORE installation)
    │   │   │   ├── 10-redis-failover.sh
    │   │   │   └── 99-summary.sh
    │   │   └── post/              # Hook scripts (run AFTER installation)
    │   │       ├── 10-redis-validation.sh
    │   │       └── 99-summary.sh
    │   ├── tests/
    │   │   └── test-redis-hooks.sh        # Unit tests for hook scripts
    │   ├── preinstall-orchestrator.yaml   # SSM document (downloads & runs pre-install scripts)
    │   ├── postinstall-orchestrator.yaml  # SSM document (downloads & runs post-install scripts)
    │   └── README.md
    └── hooks.tf               # Uploads scripts to S3, creates SSM documents
```

## How It Works

### 1. Script Storage (S3)
- Bucket created by storage module via `bucket_requests` output (dependency inversion pattern)
- Bucket name: `org-platform-hooks-{namespace}` (e.g., `org-platform-hooks-glad-fawn`)
- Scripts versioned for audit trail, lifecycle managed by storage module
- IAM policies grant maintenance window role read access

### 2. SSM Document Orchestration
- Custom SSM documents (`ORG-Universal-PreInstall-Linux`, `ORG-Universal-PostInstall-Linux`)
- Downloads scripts from S3 to instance
- Executes scripts in alphabetical order (controlled by numeric prefix)
- Aggregates exit codes and reports results

### 3. Maintenance Window Integration
- Pre-install hook runs before installation via `PreInstallHookDocName` parameter
- Post-install hook runs after installation via `PostInstallHookDocName` parameter
- Applied to ALL maintenance windows automatically

## Redis Failover Logic

### Pre-Install (10-redis-failover.sh)
1. Detects if redis-cli installed
2. Checks if Redis service running
3. Determines Redis role (master/slave)
4. **If master**: Checks replication topology:
   - **Standalone (0 replicas)**: Safe to patch immediately
   - **Master with replicas**: Checks for Sentinel availability
     - **Sentinel available**: Triggers failover, waits for demotion (60s timeout)
     - **No Sentinel**: Aborts patching (exit 1) - requires manual intervention
5. **If replica**: Safe to patch immediately

### Post-Install (10-redis-validation.sh)
1. Waits for Redis to respond to PING (120s timeout)
2. Validates replication status if replica
3. Checks Sentinel health status
4. Ensures instance seen as healthy before proceeding

## Exit Codes

Scripts must follow this contract:

- **Exit 0**: Success or service not found (no-op)
- **Exit 1**: Critical failure - abort patching
- **Exit 2**: Warning - continue patching (logged for review)

## Adding New Service Hooks

To add checks for a new service (e.g., PostgreSQL):

1. Create pre-install script: `platformer/configuration-management/hooks/linux/pre/20-postgresql-safety.sh`
2. Create post-install script: `platformer/configuration-management/hooks/linux/post/20-postgresql-validation.sh`
3. Follow the exit code contract
4. Use numeric prefix to control execution order (10, 20, 30, etc.)
5. Scripts automatically uploaded to S3 on next Terraform apply

**No Terraform changes required!** Scripts are discovered via `fileset()`.

## Testing

Run unit tests:
```bash
bash platformer/configuration-management/hooks/tests/test-redis-hooks.sh
```

Tests validate:
- Scripts execute correctly when service not installed (no-op)
- Proper file permissions and structure
- Error handling with `set -e`
- Correct shebang lines
- Numeric prefixes for ordering

## Deployment

### Local Testing (terraform.tfvars)
```hcl
states = [
  "patch-management-legacy-prod"
]
```

### Production Deployment
1. Hooks auto-enable when patch management configured
2. S3 bucket created: `org-platform-hooks-{namespace}`
3. Scripts uploaded to S3
4. SSM documents created
5. Maintenance windows automatically reference hooks

## Example: Maintenance Window Task

```hcl
resource "aws_ssm_maintenance_window_task" "patch" {
  task_arn = "AWS-RunPatchBaseline"

  task_invocation_parameters {
    run_command_parameters {
      parameter {
        name   = "PreInstallHookDocName"
        values = ["ORG-Universal-PreInstall-Linux-{namespace}"]
      }

      parameter {
        name   = "PostInstallHookDocName"
        values = ["ORG-Universal-PostInstall-Linux-{namespace}"]
      }

      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }
    }
  }
}
```

## Benefits

1. **Zero Configuration**: No tags, no special setup required
2. **Scalable**: Works for 1 instance or 10,000 instances
3. **Safe**: Redis masters demoted before patching
4. **Validated**: Post-patch health checks ensure stability
5. **Extensible**: Add new service checks without code changes
6. **Auditable**: All executions logged in SSM
7. **Tested**: Unit tests ensure reliability

## Future Enhancements

Potential services to add hooks for:
- PostgreSQL (pause replication, wait for sync)
- Kafka (graceful broker shutdown, leadership transfer)
- Elasticsearch (shard allocation awareness)
- RabbitMQ (drain connections, cluster sync)

All follow the same pattern: detect → act → validate.
