# ArchPACS

(WIP) Domain orchestration for ArchPACS medical imaging PACS deployments using dependency inversion pattern.

## Overview

This module declares infrastructure requirements for ArchPACS servers without creating resources directly. It generates requests for:

- **Compute classes** (EC2 instances) - Rocky Linux 8 instances per tenant
- **Maestro automation** - PACS installation via `new_site_install.yml` recipe
- **RDS clusters** - LifeImage CNS database (PostgreSQL)
- **S3 buckets** - File transfer, backups, logs
- **distribute.cfg** - Rendered from Terraform outputs for Maestro topology input

## Approach: Native Rocky Linux 8 + Maestro

ArchPACS requires bare-metal/VM Linux with RPM-based package management. Maestro (`acme-org/mstro-automation-tool`) is the org's production-grade distributed automation framework purpose-built for ArchPACS. It handles correct repo access, package ordering, DB init, service configuration, side module management, and post-install validation.

```
Terraform (infrastructure)              Maestro (application)
========================               ====================
EC2 instances (Rocky 8)          -->   new_site_install.yml
RDS Aurora PostgreSQL            -->   DB connection config
S3 buckets                       -->   File transfer / logs
Security groups (SSH + PACS)     -->   SSH trust + service ports
EBS volumes (/opt/imsdb)         -->   PACS data storage
distribute.cfg generation        -->   Maestro topology input
```

### Why Maestro (not Docker)

The previous Docker-based approach was blocked because:
- `build.vendor.example.com` repos return 404s on `/current/` symlinks inside containers
- The `pacsUpgradeTools` tarball was unavailable
- The full `pacsInstaller`/`apcsRelease` install sequence was not understood

Maestro solves all of these. It is fundamentally incompatible with containers (requires SSH, systemd, RPM, direct host access) but works natively on Rocky Linux 8 EC2 instances.

### Integration Seam: distribute.cfg

Terraform knows instance IPs, hostnames, and server types. Maestro needs these in its proprietary INI format (`distribute.cfg`). The module templates this from Terraform outputs.

## Architecture

ArchPACS deployments consist of multiple server types:

- **ModalityWithDiskmon** - Image storage servers with disk monitoring (depot/archive)
- **DicomMasterService** - Core DICOM master database service
- **DistributionServer** - Distribution/orchestration server (Maestro runs here)
- **MasterDatabaseBroker** - Master database with full PACS services
- **WebServer** - Frontend web portal servers

The Maestro orchestrator runs on one designated node (must have `DistributionServer` type), SSHs into all other PACS nodes, and executes recipe tasks with dependency ordering.

## Usage

### State Fragment Example

```yaml
services:
  tenants:
    test:
      entitlements: [archpacs.*]

  archpacs:
    ec2-poc:
      maestro:
        pacs_version: "PACS-5-8-1-R32"
        orchestrator_class: depot

      compute:
        depot:
          type: ec2
          count: 1
          ami_filter: "Rocky-8-EC2-Base-*-x86_64-*"
          ami_owner: "792107900819"
          instance_type: t3.medium
          server_type: "ModalityWithDiskmon"
          applications:
            - type: ansible
              playbook: maestro-bootstrap
              params:
                SERVER_TYPE: "ModalityWithDiskmon"
                ORCHESTRATOR: "true"

        database:
          type: ec2
          count: 1
          ami_filter: "Rocky-8-EC2-Base-*-x86_64-*"
          ami_owner: "792107900819"
          instance_type: t3.medium
          server_type: "DicomMasterService"
          applications:
            - type: ansible
              playbook: maestro-bootstrap
              params:
                SERVER_TYPE: "DicomMasterService"
                ORCHESTRATOR: "false"

      rds:
        lifimage_cns:
          engine_version: "15.15"
          instance_class: "db.t4g.medium"
          instances: 1
          database_name: "cnstest"

      s3:
        - purpose: file-transfer
        - purpose: logs
          retention_days: 7
```

### Local Development

```bash
# terraform.tfvars
states = ["archpacs-test"]

# Deploy
terraform plan
terraform apply
```

## Dependency Inversion Flow

```
1. terraform apply
   +-- Compute module provisions Rocky 8 EC2 instances
   +-- Storage module creates RDS Aurora + S3 buckets
   +-- Networking module creates VPC/subnets/SGs
   +-- ArchPACS module renders distribute.cfg

2. Configuration-management module uploads to S3:
   +-- maestro-bootstrap playbook
   +-- distribute.cfg (rendered)

3. SSM runs maestro-bootstrap on ALL instances:
   +-- Runner nodes: install Maestro, deploy distribute.cfg, wait
   +-- Orchestrator node: install Maestro, deploy distribute.cfg,
       then run: maestro_orchestrator new_site_install.yml \
                   --exit-on-completion \
                   -r pacs_version=PACS-5-8-1-R32

4. Maestro handles the rest:
   +-- SSH into all runners
   +-- Install PACS packages from build.vendor.example.com
   +-- Configure databases, services, side modules
   +-- Start and validate all PACS services
```

## Files

| File | Purpose |
|------|---------|
| `variables.tf` | Input variables (config, tenants, networks) |
| `locals.tf` | Deployment x tenant iteration + Maestro orchestration data |
| `main.tf` | RDS/S3 requests + distribute.cfg rendering |
| `outputs.tf` | Dependency inversion exports + Maestro metadata |
| `templates/distribute.cfg.tftpl` | Terraform template for Maestro's distribute.cfg |
| `ansible/maestro-bootstrap/playbook.yml` | Maestro installation + PACS deployment playbook |

## Maestro Key Facts

| Aspect | Detail |
|--------|--------|
| Architecture | Orchestrator-Runner model over SSH |
| Greenfield recipe | `new_site_install.yml` (requires EL8+) |
| OS requirement | Rocky / CentOS / RHEL 8+ |
| Install method | Tarball from `packages.vendor.example.com` |
| Critical input | `distribute.cfg` (INI-format, defines server topology) |
| Container support | None -- fundamentally bare-metal/VM only |
| Repo | `acme-org/mstro-automation-tool` |

## Current Status (2026-02-13)

Maestro `new_site_install` recipe launches and gets through the initial validation tasks. Three blockers remain before the recipe can complete end-to-end:

### 1. EBS volumes not formatted/mounted (`run-precheck` failure)

`precheck` fails with: `Missing required MountPoint(s): ["/opt/imsdb"]`

The state fragment declares `ebs_volumes` with `mount: /opt/imsdb`, and Terraform attaches the EBS volume, but nothing formats or mounts it at the OS level. On Nitro instances (t3.medium), `/dev/sdf` appears as `/dev/nvme1n1`.

**Fix**: Add an early playbook task (or user-data script) to:
1. Detect the attached EBS device (`/dev/nvme1n1` or `/dev/sdf`)
2. Format as xfs if no filesystem exists
3. Mount at `/opt/imsdb`
4. Add to `/etc/fstab`

### 2. Hostname too long (`run-precheck` failure)

`precheck` fails with: `hostname doesn't meet the maximum length requirement, maxlength=29`

AWS default hostnames like `ip-172-31-33-127.us-east-2.compute.internal` are 50+ chars. Maestro's precheck enforces a 29-char max.

**Fix**: Add an early playbook task to set a short hostname derived from deployment name + server type (e.g., `poc-depot01`, `poc-db01`). Must also update `/etc/hosts` so the short hostname resolves.

### 3. PKI certificate bundle not staged (`pki-download` failure)

The `pki-download` recipe task expects a pre-staged PKI tarball at `/tmp/pki*.tar.gz` on the orchestrator. Per the recipe prerequisites:

> PKI cert bundle for the client must be pre-downloaded from LCManager and copied to /tmp on the orchestrator server

This is a manual step in Maestro's workflow. Without PKI certs, downstream tasks like `sync-repos` (which contacts `packages.vendor.example.com` with mTLS) and `run-pacsInstaller` will also fail.

See the [PKI Deep Dive](#pki-deep-dive) section below for a full analysis of the problem, the upstream dependencies, and viable options.

### Other notes

- `--remove-state` flag is in the orchestrator command to clear stale state between runs
- All `no_log: true` directives are commented out for dev debugging -- re-enable before production
- `MAESTRO_TESTING=1` environment variable can skip `run-precheck` for quick iteration, but the hostname and mountpoint issues will still cause problems for later recipe tasks
- `install-update-depstart` succeeds (outbound internet to `build.vendor.example.com` works)
- `set-timezone` and `assert-pacs-branch` pass (distribute.cfg has `[DeploymentInfo]` and `[SiteInfo]` sections)

### Resolved issues (for reference)

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Artifactory RPM download hanging | No outbound to Artifactory from EC2 | Extended upload system with `type: url`, RPM pushed to S3 at plan time |
| SCP to runners hanging | No SSH ingress between compute classes | Shared self-referencing security group in `security-groups.tf` |
| SSH private key "invalid format" | SSM `get-parameter --output text` strips trailing newline | Append `\n` to `content:` in copy task |
| Orchestrator binary not found | RPM places binary at `python/bin/orchestrator`, not `bin/orchestrator` | Split into `maestro_base_dir` + `maestro_bin_dir` vars |
| Screen/tmux interactive prompt crash | No TTY in SSM execution context | Added `--no-screen-check` flag |
| Version string parse error | Maestro expects `5-8-1-R32`, not `PACS-5-8-1-R32` | Removed `PACS-` prefix from state fragment and playbook default |
| distribute.cfg missing fields | Recipe tasks grep for `PacsVersion` and `DefaultTimeZone` | Added `[DeploymentInfo]` and `[SiteInfo]` sections |

## PKI Deep Dive

The PKI blocker is the hardest remaining problem. Unlike the EBS and hostname issues (which are straightforward playbook tasks), PKI is entangled with a chain of centralized vendor services that we don't control and can't easily replicate.

### What the PKI actually is

ArchPACS uses a **custom, in-house PKI** managed by a centralized service called **LCM (Life Cycle Manager)**. LCM generates a per-client `.tar.gz` bundle containing **60+ certificate/key files** in various formats (PEM, JKS, P12, DER) that secure communication between PACS components and with the vendor's backend services.

The bundle includes:

| Files | Purpose |
|-------|---------|
| `client.crt`, `client.key`, `client.pem` | **mTLS with `packages.vendor.example.com`** -- required for `sync-repos`, yum repo access, and most vendor backend communication |
| `*-pacsServices.*` | Inter-service TLS between PACS Java components |
| `*-enhancedViewer.*`, `*-dicomResourceProvider.*`, `*-waveletServer.*` | Per-component service certificates |
| `ca-root.crt`, `ca-intermediary.*`, `ca-intermediary-trust.jks` | Two-tier CA chain (shared Root CA -> per-client Intermediate CA) |
| `billinguploader.aws.json`, `client-ev-aws-cred.json` | AWS credentials piggy-backing on the PKI distribution mechanism |
| `cloudfront-private-key.der`, `cloudfront-key-pair-id.txt` | CloudFront signing keys |

Certificates expire every **2-3 years**. If they expire, the PACS enters a "code blue" (major tenant outage). LCM runs a cron (`findexpired`) that opens ServiceNow change requests when certs are approaching expiry.

### Where the PKI comes from

LCM is a **standing, centralized vendor service** at `lcm.vendor.example.com`. It is not something we deploy -- it's shared infrastructure managed by the Delivery Automation team. Its full stack is roughly 15 containers (Pyramid/Python web app, Twisted event processor, Twisted scheduler, Crossbar.io WAMP router, MongoDB, MySQL, PostgreSQL, nginx, plus mock services for dev). Deploying per-tenant LCM instances is not practical.

The actual certificate generation is done by **Python 2 scripts** using M2Crypto, pyOpenSSL, `openssl` CLI, and Java `keytool` (specifically Vendor JDK 1.8 -- newer JDKs break compatibility). The PKI directories are tracked as **Mercurial repositories**. The scripts are deeply coupled to internal `corp.*` libraries, MongoDB queries, and PACS-version-specific branching logic.

### How other teams handle this

**Cloud Platform team** (`cpt-pacs-cloud-pipeline`): Their Ansible `pki` role makes two LCM API calls at deployment time:

```
# Download the full PKI tarball
GET https://lcm-web.vendor.example.com/api/v1/download_client_pki/{client_id}
Header: X-lcm-authtoken: <token>

# Download client certs separately (for extservices mTLS / yum repo auth)
GET https://lcm-web.vendor.example.com/api/v1/get_client_pki/{client_id}?clientcerts=1
Header: X-lcm-authtoken: <token>
```

If no PKI exists for the client yet, they generate one first:

```
POST https://lcm-web.vendor.example.com/api/v1/pki/{client_id}
Header: X-lcm-authtoken: <token>
Body: {"action": "updatepki", "forceupdate": "true"}
```

The tarball is extracted via Mercurial clone (the tarball is an hg repo) into `/opt/vendor/etc/pki` and `/usr/local/tools/src/PACSinstall/site-config/pki`. Client certs are written to `/opt/vendor/etc/yum/certs/` for yum/extservices mTLS.

Their LCM auth token is stored in AWS Secrets Manager (`cloud-platform-team/lcm` in `us-east-1`) and loaded by Jenkins at runtime. **These tokens are IP/host-bound and managed by the Delivery Automation team.**

**Platform team** (`PROJ-5012`, in-progress): Alex Chen is working on automating PKI fetch for Maestro-based installs using the same LCM API. This ticket is directly relevant to our work.

### Why we can't just use AWS PKI instead

The ArchPACS PKI is not general-purpose TLS. Replacing it with ACM or AWS Private CA would require:

- Modifying ArchPACS itself to accept different cert paths, formats, and trust chains
- Convincing `packages.vendor.example.com` to trust our CA (it validates `client.crt` against its own `SSLCACertificateFile`)
- Generating JKS keystores that Java PACS components accept
- Replicating the exact file layout that dozens of PACS services expect at hardcoded paths

This is not feasible without changes to the PACS application code, which is out of scope.

### Why we can't deploy LCM per-tenant

LCM is a monolithic system designed as a single shared instance for all tenants. A minimal functional instance requires MongoDB, MySQL (for System Catalog), PostgreSQL, a WAMP router (Crossbar.io + its own MongoDB), the web app, event processor, scheduler, and nginx -- roughly 7+ containers with significant memory/CPU overhead. Its PKI generation depends on a shared Root CA, Python 2 with M2Crypto, Mercurial, Vendor JDK 1.8, and internal `corp.*` libraries. The code is available (`acme-org/lcm-*` repos) but is not designed for isolated deployment.

### Viable paths forward

**Option A: Call the central LCM API (recommended)**

Use the same API the Cloud Platform team uses. This requires:

1. A registered client in LCM with a `client_id` (tenants likely already exist)
2. An LCM auth token from the Delivery Automation team, stored in SSM or Secrets Manager
3. Playbook tasks to call the API, extract the tarball, and stage it to `/tmp/pki/`

This is what PROJ-5012 is implementing. The constraint is that **auth tokens are IP/host-bound and managed by another team** -- we cannot self-service them, and changes to the execution environment (new IP ranges, new runners) require coordination.

For our module, this would mean adding a pre-Maestro playbook step that:
- Retrieves the LCM token from SSM Parameter Store
- Calls `GET /api/v1/download_client_pki/{client_id}`
- Extracts the tarball to `/tmp/pki/` (where Maestro's `pki-download` task expects it)
- Writes `client.crt` and `client.key` to `/opt/vendor/etc/yum/certs/`

New state fragment fields needed: `client_id` (numeric LCM client identifier).

**Option B: Manual PKI staging via S3 (interim workaround)**

Same pattern as the Maestro RPM in `upload.yaml`:

1. Manually download the PKI bundle from LCM (via web UI or `pki-tool`)
2. Upload the tarball to the S3 upload bucket
3. Add an entry to `upload.yaml` so it gets staged to `/tmp/` on the orchestrator

This avoids the LCM API dependency entirely but requires a human to download and upload the PKI bundle for each new tenant or renewal. Acceptable for dev/testing; not viable for production at scale.

**Option C: Skip PKI for dev by using `MAESTRO_TESTING=1` + local RPM mirror**

For development iteration only: skip the PKI-dependent recipe steps (`sync-repos`, mTLS to extservices) by pre-staging RPMs via S3 and using the `MAESTRO_TESTING=1` flag. This lets us validate the rest of the install pipeline without solving PKI first. Does not produce a functional PACS (no inter-service TLS), but unblocks work on the other blockers.

### The `distribute.cfg` shortcut

LCM also serves `distribute.cfg` at `GET /distributeconf/{deployment_id}?raw=1` with **no authentication required**. However, we are already generating `distribute.cfg` from Terraform outputs, which is preferable since it uses real AWS instance data (IPs, hostnames) rather than whatever LCM has registered.

### Key references

| Resource | Location |
|----------|----------|
| LCM PKI bundle generation docs | [Confluence: LCM space](https://example.atlassian.net/wiki/spaces/LCM/pages/1108803774) |
| PKI update procedure (SRE Ops) | [Confluence: SREOPS space](https://example.atlassian.net/wiki/spaces/SREOPS/pages/1147011789) |
| pki-tool CLI docs | [Confluence: ~jsmith](https://example.atlassian.net/wiki/spaces/~jsmith/pages/1732280396) |
| Cloud Platform PKI implementation | `acme-org/cpt-pacs-cloud-pipeline` -> `ansible/roles/pki/tasks/main.yml` |
| PROJ-5012 (our PKI automation ticket) | [Jira: PROJ-5012](https://example.atlassian.net/browse/PROJ-5012) |
| Maestro `new_site_install` recipe | `acme-org/mstro-automation-tool` -> `recipe/new_site_install.yml` |
| LCM repos (for reference only) | `acme-org/lcm-*` (19 repos, Python 2/3 mix) |
| IPODVM / IPRP (test VM system) | `acme-org/cpt-pacs-ami-builder`, Jenkins `AutomationTeam/IPOD-VM` |

### What is an IPODVM?

IPODVM (IPOD-VM) is the vendor's internal ephemeral virtual machine system for building and testing ArchPACS deployments. It provisions EC2 instances, installs PACS via Maestro, and is used by QA for regression testing and by the Cloud Platform team to build Golden AMIs (`cpt-pacs-ami-builder`). It is orchestrated via IPRP (IPOD Resource Provisioning Portal) and Jenkins pipelines. **We do not need to deploy an IPODVM** -- it is a build/test harness, not a runtime component. Our module replicates the same end result (Maestro-based PACS install on EC2) through Terraform + the maestro-bootstrap playbook.

## Production Considerations

**High Availability:**
- Deploy multiple depot servers (`count: 2+`)
- Multi-AZ RDS clusters (`instances: 3`)

**Security:**
- Private subnets only
- Security groups: SSH (22) between PACS nodes, DICOM (104), PostgreSQL (5432), Web (8080), Maestro dashboard (8000)
- RDS encryption at rest and in transit

**Networking:**
- SSH trust between all PACS instances (Maestro requirement)
- Outbound access to `packages.vendor.example.com` (Maestro download) and `build.vendor.example.com` (PACS packages)

**Storage:**
- gp3 SSD for OS and application volumes
- sc1 HDD for DICOM image archives (production, TB-scale)
- S3 for file transfer, backups, logs with lifecycle policies
