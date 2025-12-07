# Secrets

Cross-account secret replication. Reads secrets from authoritative source accounts and creates local copies in deployment accounts.

## Problem

Shared credentials (API keys, tokens, certificates) live in a central infrastructure account. Platformer deploys to arbitrary accounts (dev, staging, production), and workloads in those accounts need access to the credentials at runtime.

## Solution

Rather than granting every workload cross-account IAM access to the source, this module replicates secrets locally once at apply time. Downstream consumers read from their own account's Secrets Manager using standard IAM roles—no cross-account chains, no assume-role complexity, no per-module provider aliases.

## Benefits

- **Simplified IAM** - Workloads use single-account permissions
- **Reduced Blast Radius** - Compromised workload can't access source account
- **Performance** - No cross-account API calls at runtime
- **Consistent Access Patterns** - All secrets read the same way

Currently supports replication from the infrastructure account. Adding new source accounts requires one provider alias and one filter block.
