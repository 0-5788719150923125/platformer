# Observability

LGTM stack (Loki, Grafana, Tempo, Mimir) for centralized logging and observability.

## Concept

Deploys a self-contained observability stack on a dedicated EKS cluster. Uses dependency inversion to request infrastructure from other modules - the mere presence of `services.observability` auto-enables compute, storage, applications, and configuration-management.

Grafana Alloy agents on EC2 instances collect logs and ship them to Loki running in Kubernetes.

## Architecture

The module generates infrastructure requests that other modules fulfill:

- **EKS Cluster** - Compute module creates dedicated cluster for LGTM stack
- **S3 Buckets** - Storage module creates buckets for Loki chunks and ruler storage
- **Helm Charts** - Applications module deploys Loki and Grafana
- **Alloy Agents** - Configuration-management deploys agents via Ansible+SSM

## Components

**Loki** - Log aggregation with S3-backed storage. Supports SingleBinary, SimpleScalable, and Distributed deployment modes.

**Grafana** - Visualization dashboard with pre-configured Loki datasource.

**Alloy** - Log collection agents on EC2 instances. Tails configured log files and ships to Loki.

## Design Decisions

- **Node Role Access** - S3 access via EKS node role instead of IRSA to avoid two-apply dependency
- **Deterministic Names** - Bucket names constructed as `purpose-namespace` to avoid circular dependencies
- **Synthetic Tenant** - Injects "platform" tenant so compute module doesn't filter out observability cluster
- **K8s DNS Endpoints** - Alloy agents use cluster DNS for deterministic Loki endpoint

## Cross-VPC Limitation

Currently assumes EC2 instances and EKS cluster are in the same VPC. Alloy agents can't reach Loki across VPC boundaries without additional networking (NLB or VPC endpoint).
