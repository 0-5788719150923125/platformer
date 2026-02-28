# Autonomous Systematic Mechanical Reconcilliation

Self-service framework for {{ .user.firstName }}.

A **Platformer** combines Platform Architecture + Terraform(er), reflecting a team identity and technical approach. Like the game genre, we build foundations for others to rely upon. The "-former" suffix is a nod to modern AI (transformers) and the technological singularity within us all.

## Architecture

Account and region-level orchestration with modular services, controlled via state fragments.

**Design principles:**
- Service-level grouping
- Single state per account/region
- State fragment-based configuration (GitOps)
- Module-owned defaults

### Project Structure

```
.github/
├── actions/                    # Reusable compositions
└── workflows/terraform.yml     # Unified matrix deployments

platformer/
├── access/                     # Service module
├── applications/               # Service module
├── archbot/                    # Service module
├── archivist/                  # Service module
├── archorchestrator/           # Service module
├── archpacs/                   # Service module
├── archshare/                  # Service module
├── auto-docs/                  # Service module
├── build/                      # Service module
├── clairevoyance/              # Service module
├── compute/                    # Service module
├── config/                     # Service module
├── configuration-management/   # Service module
├── domains/                    # Service module
├── hashing/                    # Service module
├── learn/                      # Documentation
├── legacy/                     # Service module
├── networking/                 # Service module
├── next/                       # Documentation
├── observability/              # Service module
├── portal/                     # Service module
├── preflight/                  # Service module
├── present/                    # Documentation
├── resolver/                   # Service module
├── scripts/                    # Documentation
├── secrets/                    # Service module
├── states/                     # Documentation
├── storage/                    # Service module
├── tenants/                    # Service module
├── tests/                      # Test automation
├── workspaces/                 # Service module
├── main.tf                     # Service orchestration
└── top.yaml                    # Multi-account targeting
```
## Prerequisites

The following tools must be available in `PATH` for full functionality:

| Tool | Type | Modules |
|------|------|---------|
| `aws` | discrete | compute |
| `docker` | discrete | portal |
| `docker compose` or `docker-compose` | any | portal |
| `helm` | discrete | compute |
| `kubectl` | discrete | compute |

## Available Services

- **access**: Centralized access control reporting using dependency inversion. Modules declare the IAM roles, security groups, and resource policies they provision, and the audit module aggregates them into a single JSON report rendered in AWS-native format. ([docs](./access/README.md))
- **applications**: Data transformation layer for application deployment. Enriches application requests with file paths and routes them to appropriate deployment modules. ([docs](./applications/README.md))
- **archbot**: Event-driven AI assistant for Atlassian tickets. Ingests webhook events via API Gateway, rebuilds full ticket context from the REST API, delegates to a configurable AI backend (Bedrock, Devin, or test), and posts responses as comments. ([docs](./archbot/README.md))
- **archivist**: Produces a scrubbed, versioned tarball of the `platformer/` codebase on every `terraform apply`. The archive is safe to distribute - sensitive strings (AWS account IDs, internal domain names, S3 bucket names, and account-specific targets) are replaced with generic placeholders before packaging. ([docs](./archivist/README.md))
- **archorchestrator**: Domain orchestration module for ArchOrchestrator (IO Cloud / SaaSApp) deployments on AWS ECS Fargate. ([docs](./archorchestrator/README.md))
- **archpacs**: (WIP) Domain orchestration for ArchPACS medical imaging PACS deployments using dependency inversion pattern. ([docs](./archpacs/README.md))
- **archshare**: Domain orchestration module for Archshare medical imaging platform. ([docs](./archshare/README.md))
- **auto-docs**: Automatic documentation generator for Platformer modules - parses `variables.tf` files and generates `SCHEMA.md` with YAML examples. ([docs](./auto-docs/README.md))
- **build**: Golden AMI builds for EC2 classes using Packer with SSM communicator. Extracted from compute to sit earlier in the dependency graph, enabling direct S3 access during builds. ([docs](./build/README.md))
- **clairevoyance**: Medical AI inference platform on AWS SageMaker. ([docs](./clairevoyance/README.md))
- **compute**: Unified compute provisioning with type-based routing. Single configuration interface for EC2, EKS, and future compute platforms. ([docs](./compute/README.md))
- **config**: Configuration resolution via YAML state fragments. Loads, deep-merges, and extracts service configurations. ([docs](./config/README.md))
- **configuration-management**: Automated configuration management for EC2 instances using AWS Systems Manager. ([docs](./configuration-management/README.md))
- **domains**: Route53 zone lookup and ACM wildcard certificate provisioning with DNS validation. ([docs](./domains/README.md))
- **hashing**: Deterministic namespace generation for parallel deployments. ([docs](./hashing/README.md))
- **legacy**: Disposable EC2 instance with Atlantis pre-built via Packer. ([docs](./legacy/README.md))
- **networking**: VPC and subnet management with deterministic CIDR allocation. ([docs](./networking/README.md))
- **observability**: LGTM stack (Loki, Grafana, Tempo, Mimir) for centralized logging and observability. ([docs](./observability/README.md))
- **portal**: Ephemeral Port.io integration for compute instance catalog visualization and self-service actions. ([docs](./portal/README.md))
- **preflight**: Reusable dependency validation utilities for checking CLI tool availability. ([docs](./preflight/README.md))
- **resolver**: Dependency resolution engine. Determines which modules need to be enabled based on service configurations. ([docs](./resolver/README.md))
- **secrets**: Cross-account secret replication. Reads secrets from authoritative source accounts and creates local copies in deployment accounts. ([docs](./secrets/README.md))
- **storage**: Centralized S3 bucket provisioning using dependency inversion. Modules declare their storage needs, the storage module creates and manages the resources. ([docs](./storage/README.md))
- **tenants**: Centralized tenant registry and validation. ([docs](./tenants/README.md))
- **tests**: Root-level test suites and the module test runner. ([docs](./tests/README.md))
- **workspaces**: Enables workspace-specific variable overrides using `terraform.tfvars.{workspace}` files. ([docs](./workspaces/README.md))

**Auto-enabling services**: Some modules (storage, compute) automatically enable when other modules need them, via dependency inversion. See [Dependency Inversion Pattern](#dependency-inversion-pattern) below.

## Local Development

For a detailed walkthrough with practical examples, see [`learn/1-getting-started.md`](./learn/1-getting-started.md).

```bash
terraform init
terraform plan
terraform apply
terraform destroy
```

Configure services via state fragments in `terraform.tfvars`:
```hcl
# terraform.tfvars
states = ["configuration-management-hourly", "compute-windows-test"]
```

**Optional**: Override the AWS profile or region:
```hcl
# terraform.tfvars
aws_profile = "example-account-prod"  # Default: example-platform-dev
aws_region  = "us-west-2"         # Default: us-east-2
states = ["configuration-management-hourly"]
```

**Note**: The provider automatically uses the profile specified in `var.aws_profile` (defaults to `example-platform-dev`). Profile names come from your `~/.aws/config` file, and the account ID is automatically derived from the authenticated session.

## Workspace-Specific Configuration

Create `terraform.tfvars.{workspace}` files to override variables per environment:

```bash
terraform workspace new nginx
cat > terraform.tfvars.nginx <<EOF
aws_profile = "example-account-1"
owner       = "BC"
states      = ["nginx-instances"]
EOF
terraform apply
```

See [`workspaces/README.md`](./workspaces/README.md) for details.

## Testing

This project includes a comprehensive test suite using `terraform test`.

```bash
# Run all tests
terraform test

# Run specific test file
terraform test -filter=tests/variables.tftest.hcl
```

**Test Coverage:**
- **Variables** - Input validation rules (AWS account ID format, profile names, region format)
- **Modules** - Module initialization, configuration acceptance, and default values
- **Conditionals** - Service auto-enabling and conditional module creation
- **Integration** - Cross-module integration (networking + compute, applications + compute)

Test files are located in `tests/`:
- `variables.tftest.hcl` - Input validation tests
- `modules.tftest.hcl` - Module interface and configuration tests
- `conditionals.tftest.hcl` - Service enablement tests
- `integration.tftest.hcl` - Cross-module integration tests

## CI/CD Multi-Account Deployments

For a detailed walkthrough on deploying to production, see [`learn/2-going-live.md`](./learn/2-going-live.md).

GitHub Actions deploys to multiple accounts/regions using composable state configurations:

- **AWS Organizations**: Accounts auto-discovered via `organizations:ListAccounts` API
- **`states/`**: Reusable fragments (matrix, services) - see [`states/README.md`](./states/README.md)
- **`top.yaml`**: Pattern-based targeting with state references (Salt-inspired)

```yaml
# top.yaml example
targets:
  '*-platform-dev':
    - regions-east
    - configuration-management
```

States are merged left-to-right. `matrix.regions` generates parallel deployments per account × region.

## Adding Services

For architectural patterns and design principles, see [`learn/3-module-composition.md`](./learn/3-module-composition.md).

1. Create `service-name/` with `main.tf`, `variables.tf`, `outputs.tf`
2. Add module to root `main.tf`:
   ```hcl
   module "my_service" {
     count  = contains(keys(module.config.service_configs), "my-service") ? 1 : 0
     source = "./my-service"
     namespace = random_pet.namespace.id
     config = module.config.service_configs["my-service"]
   }
   ```
3. Add output to root `outputs.tf`
4. Create state fragment in `states/my-service.yaml`:
   ```yaml
   services:
     my-service:
       # Service-specific configuration
   ```

## Dependency Inversion Pattern

Some modules provide infrastructure (buckets, instances) that other modules consume. Instead of tight coupling, we use **dependency inversion**:

- **Consumer modules** declare their needs via outputs (`bucket_requests`, `instance_parameters`)
- **Root orchestrator** (`main.tf`) detects needs and auto-enables provider modules
- **Provider modules** (storage, compute) fulfill requests without being directly referenced
- **No explicit configuration needed** - dependencies are inverted and resolved automatically

This pattern enables:
- **Decoupling**: Modules don't know about each other
- **Auto-enabling**: Provider modules activate when needed, no manual orchestration
- **Clean interfaces**: Standardized request/response schemas
- **Extensibility**: New consumers and providers integrate seamlessly

For a detailed explanation with diagrams, see [`present/05-dependency-inversion.md`](./present/05-dependency-inversion.md).

### Current Dependency Inversion Patterns

| Provider Module | Interface | Consumers | Auto-enables when |
|----------------|-----------|-----------|-------------------|
| **tenants** | `active_tenant_codes` | compute, storage, archshare | Always enabled |
| **storage** | `bucket_requests`, `rds_clusters`, `elasticache_clusters`, `s3_buckets` | configuration-management, archshare | Consumer needs storage resources |
| **compute** | `instance_parameters`, `helm_application_requests` | configuration-management, archshare | Module enabled |

See [`storage/README.md`](./storage/README.md) for detailed bucket provisioning guide and [`tenants/README.md`](./tenants/README.md) for tenant registry management.

---

## Architecture References

This project's design follows established patterns from HashiCorp, AWS, and GitOps principles:

### **GitOps Principles**
[Atlassian - What is GitOps?](https://www.atlassian.com/git/tutorials/gitops)

This project implements GitOps for infrastructure management:

- **Git as single source of truth**: All infrastructure declared in version control, no manual console changes
- **Declarative configuration**: Pure Terraform with service enablement via YAML state fragments
- **Automated deployment**: GitHub Actions deploys from Git commits (push-based CD appropriate for cloud infrastructure)
- **Multi-account targeting**: `top.yaml` + `states/` pattern inspired by [SaltStack's top file](https://docs.saltproject.io/en/latest/topics/tutorials/states_pt1.html) for declarative environment targeting
- **Auditability**: Full change history and PR-based workflow for infrastructure modifications

The `top.yaml` pattern matching (`'*-platform-dev'`, `'*dev*'`) combined with composable state files (`configuration-management`, `regions-east`) provides a declarative way to target infrastructure deployments across multiple accounts and regions without per-environment directory sprawl.

### **Module Composition**
[HashiCorp - Module Composition](https://developer.hashicorp.com/terraform/language/modules/develop/composition)

- **Flat module hierarchy**: We use a single level of child modules (not nested) for simplicity
- **Dependency inversion**: Modules receive dependencies as inputs rather than creating them (e.g., passing derived `aws_account_id` and `namespace` to modules)
- **Service-level grouping**: Each module represents a service (configuration-management, legacy) rather than individual resources

### **Multi-Region State Management**
[AWS - Multi-Region Terraform Deployments with AWS CodePipeline](https://aws.amazon.com/blogs/devops/multi-region-terraform-deployments-with-aws-codepipeline-using-terraform-built-ci-cd/)

- **One state file per account/region**: State keys use `pt-terraform/platformer/{account_id}/{region}.tfstate` structure for isolation
- **Matrix-based deployments**: GitHub Actions matrix generates parallel deployments per account × region
- **Regional resource scoping**: IAM policies use inline policies to avoid the 10-attachment limit while maintaining per-region deployments

### **Eventual Consistency & Reconciliation**
[GUN Database - Conflict Resolution with Guns](https://gun.eco/docs/Conflict-Resolution-with-Guns)

This project embraces **eventual consistency** as a design principle, inspired by distributed database systems like GUN. Rather than attempting perfect synchronization, the system converges toward a consistent state through repeated reconciliation:

- **Terraform reconciliation**: Multiple `terraform apply` runs converge infrastructure toward the declared state, handling transient failures and dependencies gracefully
- **SSM execution reconciliation**: Scheduled associations run repeatedly (e.g., every 30 minutes), ensuring eventual compliance even if individual executions fail
- **Idempotent operations**: All operations are designed to be safely repeated - SSM documents generate new passwords each run, IAM policies converge to declared permissions
- **Self-healing behavior**: Infrastructure drifts toward the desired state over time without manual intervention
- **Wildcard targeting**: `InstanceIds = ["*"]` ensures new instances are automatically included in the next reconciliation cycle

This approach prioritizes **availability and partition tolerance** over strict consistency (CAP theorem). Systems that may be temporarily unreachable or fail individual operations will eventually reach the desired state through subsequent execution cycles. The system naturally "finds balance" through continuous reconciliation rather than requiring perfect coordination.

### **One State vs Fragmented State**
[Microsoft Learn - Deep Learning Concepts](https://learn.microsoft.com/en-us/azure/machine-learning/concept-deep-learning-vs-machine-learning)

This architecture represents a shift from **sparse connectivity** to **fully-connected** infrastructure management, analogous to neural network design patterns:

- **Legacy approach** (`environment/*`): Fragmented state across multiple directories and state files, requiring orchestration tools like Atlantis. Each deployment operates with partial information about the organization, similar to sparse neural networks where "neurons in one layer connect only to a small region."

- **Current approach** (`platformer/*`): One state - every deployment converges toward the same unified configuration manifest. Each Terraform execution has complete organizational context via `top.yaml` pattern matching and AWS Organizations API, similar to fully-connected neural network layers, where "each layer is fully connected to all neurons in the layer before it." State files are scoped per account/region for isolation, but all executions reference the same codebase, configuration system, and organizational view.

The fully-connected approach enables emergent capabilities impossible with fragmented state: cross-account pattern matching, unified service deployment, and organization-wide reconciliation. Like training neural networks with complete gradient information versus partial derivatives, having one unified state allows the system to make better optimization decisions.

Terraform fundamentally performs **deeply-nested graph computations** to resolve resource dependencies. The more of the infrastructure graph Terraform can "see" in a single execution, the better it can handle complex operations like resource migrations, dependency reordering, and state refactoring. Fragmented state artificially limits graph visibility, forcing manual orchestration to coordinate changes that could be automatically resolved with complete context.

### **Twelve-Factor Infrastructure**
[The Twelve-Factor App](https://12factor.net/)

While originally designed for application development, most twelve-factor principles apply directly to modern infrastructure management. This project implements key factors that distinguish declarative, service-oriented infrastructure from traditional approaches:

- **Factor III - Config**: All environment-specific configuration lives in externalized state fragments (`states/*.yaml`), never hardcoded in modules. The same module code deploys across all accounts/regions with different configurations, eliminating per-environment codebases and enabling consistent behavior everywhere.

- **Factor IV - Backing Services**: Services (configuration-management, compute, legacy) are treated as **attached resources** that can be enabled or disabled purely through state fragments. Conditional module loading means infrastructure components attach and detach without code changes - analogous to swapping database providers via environment variables rather than hardwiring dependencies.

- **Factor IX - Disposability**: Infrastructure modules are designed for fast, clean attachment and detachment. The `legacy` module demonstrates this principle: an entire Atlantis deployment can be enabled, used, and completely removed by toggling configuration - no orphaned resources, no manual cleanup, just declarative state transitions. This "cattle not pets" approach to infrastructure components enables confident experimentation and rapid rollback.

- **Factor X - Dev/Prod Parity**: Developers run the **exact same code** locally as CI/CD runs in production, loading identical YAML state fragments through the `config` module. Traditional approaches that separate development and production configurations into different directory structures create gaps where "works on my machine" problems thrive. Here, the only difference between environments is which state fragments load and which `var.aws_region` targets - everything else is identical.

The shift from per-environment directory sprawl to service-based conditional loading represents infrastructure-as-code maturing toward the same principles that revolutionized application architecture. Services become composable, environments become configuration, and deployments become deterministic.
