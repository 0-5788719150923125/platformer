# Archshare

Domain orchestration module for Archshare medical imaging platform.

## Overview

The Archshare module orchestrates infrastructure and application deployments for the Archshare medical imaging platform. It supports multi-tenant deployments with both EC2 and EKS compute options.

**Key architecture principle**: This module uses **dependency inversion** - it generates infrastructure requests (RDS, ElastiCache, S3, Helm charts) that other modules fulfill. It creates minimal AWS resources directly, primarily orchestrating deployments.

## Architecture

```
State Fragment → Archshare Module → Infrastructure Requests → Storage/Compute Modules
                                                                         ↓
                                                                 Creates Resources
                                                                         ↓
Root main.tf ← Endpoints/Outputs ← Module Outputs
     ↓
Archshare Module (receives endpoints for application configuration)
     ↓
Application Deployment (EC2 via Ansible/SSM or EKS via Helm)
```

## Deployment Types

### EC2 Deployment (Legacy)
- Uses Ansible playbooks deployed via AWS Systems Manager (SSM)
- Docker Compose based application deployment
- Managed by separate automation (not in this module)

### EKS Deployment (Current)
- Uses Helm charts deployed directly by Terraform
- 5 charts per tenant: services, storage, transcoding, watchdog, frontend
- Kubernetes secrets created via `kubectl` script
- LoadBalancer service for frontend access

## What It Does

### 1. Infrastructure Requests (Dependency Inversion)

Generates request objects for each tenant:
- **2x RDS Aurora PostgreSQL clusters**
  - Services DB (`v3s` database)
  - Storage DB (`imagedb` database)
- **3x ElastiCache clusters**
  - Valkey for services
  - Valkey for storage
  - Memcached
- **1x S3 bucket** (DICOM image storage)
- **1x EFS filesystem** (shared storage, optional)

### 2. Receives Storage Outputs

After storage module creates resources:
- RDS endpoints and passwords
- ElastiCache endpoints
- S3 bucket names
- EFS filesystem IDs

### 3. Application Deployment (EKS Only)

For EKS tenants, generates Helm chart deployment requests:

**Services Chart** (`services-values.yaml.tpl`):
- V3 services with pgbouncer
- Sidecar proxies for Redis and Memcached

**Storage Chart** (`storage-values.yaml.tpl`):
- ImageDB services with Flyway migrations
- S3-backed DICOM storage
- JobRunr dashboard

**Transcoding Chart** (`transcoding-values.yaml.tpl`):
- DICOM transcoding services

**Watchdog Chart** (`watchdog-values.yaml.tpl`):
- Monitoring and health checks

**Frontend Chart** (`frontend-values.yaml.tpl`):
- nginx-based web UI with SSI
- API proxying to backend services
- LoadBalancer service

### 4. Kubernetes Secrets

Creates K8s secrets for each EKS tenant via script:
- `ecr-credentials` - ECR image pull secret
- `services-secret` - Database and cache config for services
- `storage-secrets` - Database and S3 config for storage
- `watchdogservices-secrets` - Database config for watchdog

### 5. Supporting Infrastructure

**Security Groups** (`security-groups.tf`):
- Archshare workload SG with RDS, ElastiCache, EFS access
- Attached to compute instances/pods

**IAM** (`iam.tf`):
- Instance profiles for EC2/EKS compute
- S3 bucket access policies

**SSM Parameters** (`parameters.tf`):
- RDS credentials stored in Parameter Store
- Used by deployment automation

## Module Structure

```
archshare/
├── main.tf                    # Infrastructure requests (RDS, ElastiCache, S3)
├── locals.tf                  # Endpoint mapping, tenant splitting (EC2 vs EKS)
├── helm.tf                    # Helm chart deployment requests (EKS only)
├── secrets.tf                 # K8s secret creation (EKS only)
├── security-groups.tf         # Security group for workload access
├── iam.tf                     # IAM roles and instance profiles
├── parameters.tf              # SSM parameter storage
├── outputs.tf                 # Request exports and endpoint outputs
├── variables.tf               # Module inputs
├── scripts/
│   └── create-k8s-secrets.sh  # K8s secret creation script
└── templates/
    ├── services-values.yaml.tpl
    ├── storage-values.yaml.tpl
    ├── transcoding-values.yaml.tpl
    ├── watchdog-values.yaml.tpl
    └── frontend-values.yaml.tpl
```

## Module Inputs

| Variable | Description |
|----------|-------------|
| `namespace` | Deployment namespace for resource isolation |
| `aws_account_id` | AWS account ID |
| `aws_region` | AWS region |
| `tenants` | List of tenant codes to deploy |
| `valid_tenants` | Registry of valid tenant codes |
| `config` | Archshare configuration from state fragment |
| `networks` | Network module outputs (VPC, subnets) |
| `compute_classes` | Compute class definitions (EC2 or EKS) |
| `compute_security_groups` | Security groups for compute instances |
| `rds_clusters` | RDS outputs from storage module |
| `elasticache_clusters` | ElastiCache outputs from storage module |
| `s3_buckets` | S3 bucket names from storage module |
| `efs_filesystems` | EFS filesystem IDs from storage module |

## Module Outputs

| Output | Description |
|--------|-------------|
| `rds_cluster_requests` | RDS requests for storage module |
| `elasticache_cluster_requests` | ElastiCache requests for storage module |
| `bucket_requests` | S3 bucket requests for storage module |
| `ansible_bucket_request` | S3 bucket request for Ansible playbooks |
| `helm_application_requests` | Helm chart requests for compute module (EKS) |
| `eks_secrets_ready` | Dependency tracking for K8s secrets |
| `config` | Configuration summary |
| `storage_endpoints` | Per-tenant storage endpoints (sensitive) |

## Usage Example

### State Fragment

```yaml
services:
  archshare:
    tenants:
      - alpha
      - demo

    # Infrastructure configuration
    rds:
      services:
        engine_version: "14.9"
        instance_class: db.t4g.medium
        instances: 1
      storage:
        engine_version: "14.9"
        instance_class: db.t4g.medium
        instances: 1

    elasticache:
      services:
        engine: valkey
        engine_version: "8.0"
        node_type: cache.t4g.small
        num_cache_nodes: 1
      storage:
        engine: valkey
        engine_version: "8.0"
        node_type: cache.t4g.small
        num_cache_nodes: 1
      memcached:
        engine: memcached
        engine_version: "1.6.22"
        node_type: cache.t4g.small
        num_cache_nodes: 1

    # Compute configuration (determines EC2 vs EKS)
    compute:
      tenants: ["alpha", "demo"]
      classes:
        archshare:
          type: eks  # or "ec2" for legacy deployments
```

### Terraform Module Call

```hcl
module "archshare" {
  source = "./archshare"

  namespace      = "poc"
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.name
  tenants      = ["alpha", "demo"]

  config                   = local.services.archshare
  networks                 = module.network
  compute_classes          = local.compute_classes
  compute_security_groups  = module.compute.security_groups

  # Dependency inversion: Pass storage outputs back to archshare
  rds_clusters        = module.storage.rds_clusters
  elasticache_clusters = module.storage.elasticache_clusters
  s3_buckets          = module.storage.s3_buckets
  efs_filesystems     = module.storage.efs_filesystems
}
```

## Dependency Flow

1. **Request Generation**: Archshare generates infrastructure requests
2. **Root Orchestration**: Root collects requests and passes to storage module
3. **Resource Creation**: Storage module creates AWS resources
4. **Endpoint Return**: Root passes storage outputs back to archshare
5. **Secrets Creation** (EKS): Script creates K8s secrets with endpoints
6. **Application Deployment** (EKS): Helm charts deployed with templated values

## Design Principles

- **Multi-tenant support**: Single deployment serves multiple isolated tenants
- **Compute flexibility**: Supports both EC2 (Ansible) and EKS (Helm) deployments
- **Clean templates**: Helm values in separate `.tpl` files, no heredoc complexity
- **Dependency inversion**: Request → fulfill pattern for infrastructure
- **Security**: Secrets in K8s, credentials in Parameter Store
- **Extensibility**: Easy to add tenants or infrastructure types

## Infrastructure Naming

**RDS Clusters**:
- `{namespace}-archshare-{tenant}-services` (database: `v3s`)
- `{namespace}-archshare-{tenant}-storage` (database: `imagedb`)

**ElastiCache Clusters**:
- `archshare-{tenant}-services-cache` (Valkey)
- `archshare-{tenant}-storage-cache` (Valkey)
- `archshare-{tenant}-memcached` (Memcached)

**S3 Buckets**:
- `{tenant}-dev-archshare-images-{unique-suffix}`

**Kubernetes Resources** (EKS):
- Namespace: `{tenant}` (e.g., `alpha`, `demo`)
- Releases: `services`, `storage`, `transcoding`, `watchdog`, `frontend`

## Environment-Specific Behavior

**Dev environments**:
- RDS: Single instance, deletion protection disabled, 1-day backups
- S3: force_destroy enabled, versioning disabled
- ElastiCache: Single node, encryption optional

**Production environments** (planned):
- RDS: Multi-instance, deletion protection enabled, 7+ day backups
- S3: force_destroy disabled, versioning enabled
- ElastiCache: Multi-node with encryption

## Testing

```bash
# Validate configuration
terraform validate

# Format code
terraform fmt -recursive

# Plan with state fragment
terraform plan -var="state_fragment=archshare-poc"

# Verify outputs
terraform output -json

# Check Helm chart generation (EKS)
terraform output -json | jq '.helm_application_requests.value'
```

## Helm Chart Versions

Current chart versions (defined in `helm.tf`):
- **services**: 2.1.2
- **storage**: 3.15.0
- **transcoding**: 2.0.6
- **watchdog**: 1.2.2
- **frontend**: 1.5.2

Charts pulled from: `oci://${var.config.ecr_registry}`

## Notes

- **EC2 deployments**: Require separate Ansible automation (outside this module)
- **EKS deployments**: Fully managed by this module via Helm
- **Security groups**: Automatically attached to compute instances/pods
- **Secrets rotation**: Manual process, update SSM parameters and K8s secrets
- **Multi-region**: Not currently supported, single region per deployment

## Future Enhancements

- Multi-region support with cross-region replication
- Automated secrets rotation
- Blue/green deployments for EKS
- ArgoCD integration as alternative to direct Helm
- Automated certificate management (ACM + cert-manager)
- Route53 DNS automation
- Monitoring and alerting integration
