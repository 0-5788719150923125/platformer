# Applications

Data transformation layer for application deployment. Enriches application requests with file paths and routes them to appropriate deployment modules.

## Concept

This module creates no AWS resources—it's a pure data pipeline. Takes application declarations from compute classes, adds file paths for scripts and playbooks, then routes by type to deployment modules:

- **SSM/Ansible** → Configuration-management module (30-minute reconciliation)
- **User-data** → Compute module (launch-time execution)
- **Helm** → Compute module (Kubernetes deployments)

## Supported Types

**Scripts** - Bash scripts deployed via SSM (continuous) or user-data (launch-time). Should be idempotent.

**Ansible** - Complex multi-step installations via SSM + Ansible. Playbooks stored in `ansible/` directory.

**Helm** - Kubernetes applications deployed to EKS clusters via Helm provider.

## Design Benefits

1. **Separation of Concerns** - Application definitions separate from deployment mechanisms
2. **Type-based Routing** - Single interface for multiple deployment methods
3. **Path Management** - Centralized file path resolution
4. **Extensibility** - New application types added without changing consumers
