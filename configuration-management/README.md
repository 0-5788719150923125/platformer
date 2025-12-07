# Configuration Management

Automated configuration management for EC2 instances using AWS Systems Manager.

## Capabilities

**Password Rotation** - Automatic rotation of local Administrator passwords on Windows instances. Stores rotated credentials in Parameter Store with instance-scoped paths.

**Patch Management** - OS patching with maintenance windows, baselines, and dynamic targeting. No instance tags required—uses SSM inventory queries to find instances by platform name and version.

**Hybrid Activations** - Manage non-AWS machines (WSL instances, on-premises servers, other clouds) through SSM.

**Application Deployment** - Run scripts and Ansible playbooks via SSM associations. Auto-discovers custom documents from the `documents/` directory.

**Generic Associations** - Use any AWS-managed SSM document for inventory collection, package management, compliance scanning, etc.

## Dynamic Targeting

Patch management uses SSM inventory data instead of tags. Query for instances by OS platform, version, and installed applications. Controlled rollouts with max instance limits and application exclusion patterns.

## Design Benefits

1. **Tag-free Operations** - No manual instance tagging required for patching
2. **Multi-tenant Safe** - Custom documents use Class+Namespace tags for isolation
3. **Lifecycle Managed** - Parameters created/destroyed with instances
4. **Extensible** - Drop new documents in `documents/` directory to deploy them
