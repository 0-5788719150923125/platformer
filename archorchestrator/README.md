# ArchOrchestrator

Domain orchestration module for ArchOrchestrator (IO Cloud / SaaSApp) deployments on AWS ECS Fargate.

## Overview

This module provisions cloud-native infrastructure for the ArchOrchestrator platform, which runs as a set of containerized services (SaaSApp, CoreApps, SaaS Router) on ECS Fargate with an MSSQL backend.

**Key architecture principle**: This module uses **dependency inversion** - it generates infrastructure requests (RDS SQL Server, S3 buckets) that the storage module fulfills. Container images are replicated from a source ECR account into a local ECR repository at apply time.

## Current Status

### Working
- ✅ ECS Fargate infrastructure (SaaSApp, CoreApps, Router services running)
- ✅ Application Load Balancer with HTTP routing to Router
- ✅ Cloud Map service discovery (dev1.io.local namespace)
- ✅ RDS SQL Server database provisioned
- ✅ S3 buckets (messaging, configuration, documents)
- ✅ DynamoDB tenant metadata table
- ✅ Tenant DynamoDB records created automatically
- ✅ S3 tenant mapping JSON (router configuration)
- ✅ Router successfully forwards requests to SaaSApp with x-tenant-id header

### Blocked
- ⚠️ **SQL Server tenant initialization** - SaaSApp returns 403 (cannot resolve tenant from database)
- Investigation complete: SaaSApp's build process uses a pre-built baseline database backup (`saasapp_baseline.bak` from AWS CodeArtifact)
- Liquibase changesets in saasapp-swl repo are upgrade migrations only, not initial schema creation
- No "create from scratch" SQL scripts exist - all initialization is done via RESTORE DATABASE from baseline backup
- Resolution requires either: (1) download and restore baseline backup, or (2) manual SQL schema creation

### Deploy

```bash
terraform apply -var-file=terraform.tfvars.archorchestrator

# Get ALB URL
terraform output archorchestrator_urls

# Test routing (will return 403 until SQL Server tenant records exist)
ALB_URL=$(terraform output -json archorchestrator_urls | jq -r '.dev1')
curl -H "Host: test.dev1.io.local" http://$ALB_URL/
```

## Architecture

```
State Fragment -> ArchOrchestrator Module -> Infrastructure Requests -> Storage Module
                         |                                                     |
                   Creates ECS,                                          Creates RDS,
                   ALB, ECR,                                             S3 Buckets
                   Cloud Map                                                   |
                         |                    <- Endpoints/Outputs <-----------+
                         v
                   SSM Parameters (deployment context for applications)
```

### ECR Image Replication

Images are published by the bakery pipeline to a source ECR in a separate AWS account. At `terraform apply` time, a `null_resource` with `local-exec` authenticates to both source and destination ECR registries, then pulls, re-tags, and pushes each image into a local ECR repository. ECS task definitions reference the local copy.

```
Source ECR (acme-saasapp-cloud-dev)     Local ECR (deployment account)
666666666666/saas-...-repo:saasapp-5.2.0  -> 555555555555/{namespace}-io:saasapp-5.2.0
```

## What It Creates

### Per Deployment

- **ECS Cluster** - one Fargate cluster per named deployment
- **ECS Services + Task Definitions** - one per service (e.g., saasapp, coreapps, router)
  - Only router is attached to ALB; saasapp and coreapps use service discovery only
- **Application Load Balancer** - HTTP listener forwarding all traffic to router
- **Cloud Map** - private DNS namespace for inter-service discovery (`{deployment}.io.local`)
- **SSM Parameters** - extensive parameter tree for application configuration:
  - Deployment context JSON (ALB URL, RDS endpoint, S3 bucket names)
  - AWS resource paths (S3 buckets, DynamoDB tables, IAM role, log group)
  - Connectivity parameters (service-to-service URLs)
  - Cell configuration (cell ID, tenant mapping location)
- **S3 Objects** - Router tenant mapping JSON (`router/tenant-mapping.json` in configuration bucket)
- **Security Groups** - ALB (HTTP from anywhere), ECS (ALB + inter-service + egress)
- **DynamoDB Table** - Tenant metadata storage (records created automatically during apply)

### Shared (Across Deployments)

- **ECR Repository** - single repo (`{namespace}-io`) with per-service image tags
- **IAM Roles** - ECS task execution role (ECR pull, CloudWatch) and application role (S3, SSM)

### Via Dependency Inversion (Storage Module)

- **RDS SQL Server** instance per deployment (standalone `aws_db_instance`, not Aurora)
- **S3 Buckets** - messaging, configuration, documents (per deployment)

## Module Structure

```
archorchestrator/
├── main.tf                # ECS, ALB, Cloud Map, SSM parameters, S3 tenant mappings
├── variables.tf           # Config schema (deployment map with ECS/RDS/S3 config)
├── locals.tf              # Deployment iteration, container image resolution, network selection
├── outputs.tf             # Dependency inversion exports (rds/bucket/compute requests)
├── ecr.tf                 # ECR repository + image replication from source account
├── security-groups.tf     # ALB, ECS security groups and rules
├── iam.tf                 # ECS task execution and application IAM roles
├── tenant-management.tf   # DynamoDB table + direct tenant record creation
└── README.md
```

## Module Inputs

| Variable | Description |
|----------|-------------|
| `namespace` | Deployment namespace for resource isolation |
| `aws_account_id` | AWS account ID (destination) |
| `aws_region` | AWS region |
| `aws_profile` | AWS profile for destination ECR authentication |
| `config` | ArchOrchestrator deployment configurations from state fragment |
| `tenants_by_deployment` | Per-deployment tenant lists from entitlements |
| `networks` | Network module outputs (VPC, subnets) |
| `rds_instances` | RDS instance outputs from storage module (endpoints, credentials) |
| `s3_buckets` | S3 bucket names from storage module |
| `ecs_clusters` | ECS cluster outputs from compute module |

## Module Outputs

| Output | Description |
|--------|-------------|
| `rds_cluster_requests` | RDS instance requests for storage module (SQL Server) |
| `bucket_requests` | S3 bucket requests for storage module |
| `compute_class_requests` | ECS cluster definitions for compute module |
| `alb_urls` | ALB DNS names per deployment (HTTP access URLs) |
| `ecs_clusters` | ECS cluster ARNs per deployment |
| `config` | Configuration summary (tenants, deployments, feature flags) |

## Usage

### State Fragment

```yaml
services:
  tenants:
    test:
      entitlements: [archorchestrator.*]

  archorchestrator:
    dev1:
      ecs:
        saasapp:
          cpu: 2048
          memory: 8192
          image: "saasapp-5.2.0-alpha.0.20260126002129765_dev"
          desired_count: 1
          port: 30000
        coreapps:
          cpu: 2048
          memory: 4096
          image: "saasapp-coreapps-5.1.16"
          desired_count: 1
          port: 17000
        router:
          cpu: 1024
          memory: 2048
          image: "saas-router-5.2.0-alpha.0.20250818214012210_dev"
          desired_count: 2
          port: 8080

      # ECR source (defaults to acme-saasapp-cloud-dev)
      ecr_source_profile: acme-saasapp-cloud-dev
      ecr_source_account_id: "666666666666"
      ecr_source_region: us-east-1
      ecr_source_repo: saas-us-east-1-deploymentecrrepository-7dc3wtgyh2tn

      rds:
        engine: sqlserver-se
        engine_version: "15.00"
        instance_class: db.m5.xlarge
        allocated_storage: 200
        multi_az: false
        deletion_protection: false
        backup_retention_period: 1

      s3:
        - purpose: messaging
          lifecycle_days: 30
        - purpose: configuration
        - purpose: documents
```

### Deploy

```bash
# Use the archorchestrator-specific tfvars
terraform plan -var-file=terraform.tfvars.archorchestrator
terraform apply -var-file=terraform.tfvars.archorchestrator

# Access the ALB
terraform output archorchestrator_urls
```

## Dependency Flow

1. **Config Resolution**: State fragment parsed by config module into deployment map
2. **Request Generation**: ArchOrchestrator emits `rds_instance_requests` and `bucket_requests`
3. **Resource Creation**: Storage module creates RDS SQL Server + S3 buckets
4. **Endpoint Return**: Root passes storage outputs (endpoints, bucket names) back to module
5. **ECR Replication**: Docker pull/tag/push copies images from source to local ECR
6. **ECS Deployment**: Task definitions reference local ECR images; services start on Fargate
7. **SSM Context**: Deployment context (ALB URL, RDS endpoint, S3 names) stored in Parameter Store

## ALB Routing

The ALB uses HTTP (port 80) with **router-only exposure**:

- **Only the router service is exposed via ALB** - saasapp and coreapps use service discovery only
- **Default action**: forwards all traffic to the router target group
- **No listener rules** - router handles all routing internally based on Host header and tenant mapping

The router extracts tenant information from the Host header (e.g., `test.dev1.io.local`), looks up the tenant in S3 configuration (`router/tenant-mapping.json`), and forwards requests to the appropriate SaaSApp backend via Cloud Map service discovery.

HTTPS, custom domains, and ACM certificates are deferred to a future phase.

## Router Configuration

The SaaS Router is the entry point for all external traffic and handles tenant-based routing to SaaSApp backends.

### Environment Variables (Synthesized Automatically)

```hcl
INSTANCE_DOMAIN_NAME      = "dev1.io.local"
SAASAPP_TENANT_BUCKET      = "io-{namespace}-dev1-configuration-{id}"
SAASAPP_TENANT_MAPPING_KEY = "router/tenant-mapping.json"
SAASAPP_DNS_TEMPLATE       = "saasapp.dev1.io.local:30000"
```

### Tenant Mapping Format

The router reads `router/tenant-mapping.json` from the configuration S3 bucket. This file maps tenant codes to UUIDs and versions:

```json
[
  {
    "code": "test",
    "id": "f41cad84-2adb-589c-8371-2333a79b583a",
    "state": "active",
    "version": "saasapp-5.2.0-alpha.0.20260126002129765_dev"
  }
]
```

**UUID Generation:** Tenant IDs are generated deterministically using `uuidv5("dns", "${namespace}.${deployment}.${tenant}")` to ensure stable identifiers across apply cycles.

**Routing Flow:**
1. Request arrives with Host header: `test.dev1.io.local`
2. Router extracts tenant code: `test`
3. Router looks up tenant in mapping file
4. Router forwards to SaaSApp with `x-tenant-id: f41cad84-2adb-589c-8371-2333a79b583a`
5. SaaSApp resolves tenant from database (tenant initialization required)

## Tenant Management

Direct tenant provisioning via bash scripts during `terraform apply`. Simple approach using AWS CLI.

**Automated during apply:**
- DynamoDB tenant metadata table creation
- DynamoDB tenant records (tenant ID, code, name, state, version)
- S3 tenant mapping JSON in configuration bucket (router reads this)
- tenants.json in documents bucket (SaaSApp reads this)

**Missing (blocks end-to-end functionality):**
- SQL Server tenant database records - SaaSApp's authoritative source of truth
- SaaSApp build process uses baseline database backup from CodeArtifact (`saasapp.releng.db/db-baseline-mssql:1.0.4`)
- No SQL scripts exist for "create from scratch" - only Liquibase migrations that assume baseline exists
- Resolution: download saasapp_baseline.bak from CodeArtifact and restore to RDS SQL Server

## ECR Source Configuration

Images live in a single ECR repository in the source account, differentiated by tag prefix:

| Tag Prefix | Service |
|------------|---------|
| `saasapp-*` | SaaSApp (Spring Boot, port 30000) |
| `saasapp-coreapps-*` | CoreApps (.NET, port 17000) |
| `saas-router-*` | SaaS Router (port 8080) |

Default source is `acme-saasapp-cloud-dev` (666666666666). Override per deployment via `ecr_source_*` fields for staging/production images.

## Infrastructure Naming

| Resource | Pattern |
|----------|---------|
| ECS Cluster | `{namespace}-{deployment}-io` |
| ALB | `{namespace}-{deployment}-io` |
| ECR Repository | `{namespace}-io` |
| RDS Instance | `{namespace}-{deployment}-io-mssql` |
| S3 Buckets | `io-{namespace}-{deployment}-{purpose}-*` |
| Cloud Map Namespace | `{deployment}.io.local` |
| SSM Parameter | `/{namespace}/archorchestrator/{deployment}/deployment-context` |
| Security Groups | `{namespace}-{deployment}-io-alb-*`, `{namespace}-{deployment}-io-ecs-*` |

## Deferred Features

### Placeholders
SSM parameters with placeholder values to satisfy SaaSApp's configuration binding:
- DynamoDB tables (gateway, job-lock)
- Lambda function (job-dispatch)
- SES email (domain, identity)
- S3 download bucket (points to configuration bucket)

Replace with real resources only when needed.

### Future Work
- ACM certificates + HTTPS listeners
- Route53 DNS records (custom domains)
- WebSocket API Gateway
- WAF v2 on ALB
- Global Accelerator
- EventBridge scheduled jobs
- Datadog/ADOT sidecar containers
- CloudWatch dashboards
