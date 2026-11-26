# Applications

Data transformation layer for application deployment. Enriches application requests with file paths and routes them to appropriate deployment modules.

## Concept

This module creates no AWS resources - it's a pure data pipeline. Takes application declarations from compute classes, adds file paths for scripts and playbooks, then routes by type to deployment modules:

- **SSM/Compose/Ansible** → Configuration-management module (30-minute reconciliation)
- **User-data** → Compute module (launch-time execution)
- **Helm** → Compute module (Kubernetes deployments)

## Supported Types

**Scripts** (`ssm`, `user-data`) - Bash scripts deployed via SSM (continuous) or user-data (launch-time). Should be idempotent. An `ssm` script gets its own SSM document with the script embedded, so it runs on any SSM-managed Linux host, EC2 or hybrid (`mi-`), with no aws CLI or S3 access on the host. `params` are exported to it, and `environment` is written to the file named by `$APP_ENV_FILE` as `KEY='value'` lines.

**Compose** (`compose`) - A Docker Compose stack from a git repository, with its whole lifecycle managed by [`scripts/compose-stack.sh`](scripts/compose-stack.sh) through an SSM association (every 30 minutes and on every change, one host at a time, stopping at the first failure):

- installs Docker Engine and the compose plugin from Docker's repositories when missing (apt, dnf, Amazon Linux)
- checks out `repository` at `ref` into `directory` (default `/opt/stacks/<name>`)
- writes `environment` as the project's `.env` (`profiles` becomes `COMPOSE_PROFILES`)
- opens `ports` in the host firewall (iptables, firewalld or ufw), as runtime rules tagged with the stack's name, re-applied by the unit at every start
- installs and enables `stack-<name>.service`, so the stack comes back after a reboot
- runs `docker compose up -d`, with `--build` when the commit or `.env` changed

Removing a compose app from state runs the script with `APP_ACTION=down` on its hosts before the association goes: containers (including profiled ones), unit, firewall rules and checkout are removed, while named volumes are kept. Ports that Docker publishes bypass the INPUT chain, so `ports` is only for host-network services. Cloud firewalls (security groups, OCI security lists) are not managed.

```yaml
services:
  applications:
    src:
      type: compose
      repository: https://github.com/example/src.git
      ref: main                       # default: the remote's default branch
      profiles: [public]
      ports: [51000-51999/udp]
      environment:                    # the .env, generic: any keys
        CHATS: trade
        PEER_SOURCES:                 # lists are joined with commas
          - https://github.com/a/b
          - https://gitlab.com/c/d#main
      hosts:                          # or `targeting`, for one shared deployment
        docker-1:
          instance_id: mi-05b3eddaa348b2030
          environment: {TRACKER_HOST: 59.src.eco}
```

**Environment** (`ssm`, `compose`) - A generic map: Terraform never looks at the keys. Values may be strings, numbers, bools or lists in YAML; the root joins lists with commas and stringifies the rest before this module sees them. Values can't contain a single quote or a line break.

**Hosts** (`ssm`, `compose`) - Instead of `targeting`, a map of named hosts, each pinned to an instance ID with its own `environment` overrides. Each host is its own deployment (`<app>-<host>`), so values that differ per host (hostnames, split source lists) stay in the fragment. Host-pinned apps are never baked into golden AMIs and don't create the compute instance role.

**Ansible** - Complex multi-step installations via the CodeBuild Ansible controller, which connects over Session Manager. Playbooks stored in `ansible/` directory. Session Manager on hybrid (`mi-`) hosts needs the SSM advanced-instances tier, so use `ssm` or `compose` for those.

**Helm** - Kubernetes applications deployed to EKS clusters via Helm provider.

## Tests

- `terraform test` (in this directory): normalization, the compose type, host expansion, validation
- `bash scripts/tests/test-compose-stack.sh`: the stack script against a throwaway repo, with real git and Docker and fake systemctl/firewall tools (no root)

## Design Benefits

1. **Separation of Concerns** - Application definitions separate from deployment mechanisms
2. **Type-based Routing** - Single interface for multiple deployment methods
3. **Path Management** - Centralized file path resolution
4. **Extensibility** - New application types added without changing consumers
