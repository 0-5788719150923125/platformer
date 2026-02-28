# Going Live: Compute Classes and Tenant Entitlements

**User Story**: *As a platform engineer, I need to deploy different server configurations for different tenants  -  one tenant needs both Windows and Linux servers, while another only needs Windows.*

This walkthrough builds on the Getting Started document. You've deployed a basic Windows compute class locally  -  now it's time to understand how tenants, classes, and entitlements compose to create differentiated infrastructure.

---

## Prerequisites

- Completed the Getting Started walkthrough
- Understanding of state fragments and local testing
- Access to the infra-terraform GitHub repository with PR permissions

---

## The Scenario

Two tenants  -  `bravo` and `training`  -  need compute infrastructure in the same environment. But their requirements differ:

- **bravo** needs both Windows and Linux servers (full suite)
- **training** only needs Windows servers

The framework solves this with **tenant entitlements**: each tenant declares which compute classes they receive. The compute module creates instances only for entitled tenant-class pairs.

---

## Step 1: Understand Compute Classes

A compute class defines a type of server. Look at an existing fragment:

```bash
cat platformer/states/compute-windows-poc.yaml
```

```yaml
matrix:
  tenants:
    alpha:
      entitlements: [compute.*]
    november:
      entitlements: [compute.*]

services:
  compute:
    windows-poc:
      type: ec2
      ami_filter: "Windows_Server-2022-English-Full-Base-*"
      ami_owner: "801119661308"
      instance_type: "t3.medium"
      count: 1
      description: "Windows Server 2022 for POC"
```

This fragment defines one class (`windows-poc`) and two tenants (`alpha`, `november`). Both tenants have `entitlements: [compute.*]`  -  the `compute.*` wildcard entitlement means they receive **all** compute classes. Since there's only one class, both tenants get one Windows instance each. Total: 2 instances.

---

## Step 2: Create a Multi-Class Fragment

Create `platformer/states/compute-multi-class.yaml`:

```yaml
# platformer/states/compute-multi-class.yaml
# Two compute classes, two tenants with different entitlements

matrix:
  tenants:
    bravo:
      entitlements: [compute.*]                # All classes
    training:
      entitlements: [compute.windows-server]   # Only windows-server

services:
  compute:
    windows-server:
      type: ec2
      ami_filter: "Windows_Server-2022-English-Full-Base-*"
      ami_owner: "801119661308"
      instance_type: "t3.small"
      count: 1
      description: "Windows Server 2022"

    rocky-linux:
      type: ec2
      ami_filter: "Rocky-9-EC2-Base-9.*x86_64"
      ami_owner: "792107900819"
      instance_type: "t3.small"
      count: 1
      description: "Rocky Linux 9"
```

### How entitlements work:

| Entitlement | Meaning |
|---|---|
| `compute.*` | Wildcard  -  tenant gets **all** compute classes |
| `compute.windows-server` | Scoped  -  tenant gets **only** the `windows-server` class |
| `compute.rocky-linux` | Scoped  -  tenant gets **only** the `rocky-linux` class |

The compute module uses these entitlements to filter the tenant × class expansion:

- **bravo** (`compute.*`) → `windows-server` + `rocky-linux` → 2 instances
- **training** (`compute.windows-server`) → `windows-server` only → 1 instance

Total: 3 instances.

---

## Step 3: Test Locally

```hcl
# terraform.tfvars
states = ["compute-multi-class"]
```

```bash
terraform plan
```

You should see 3 instances in the plan:

```
  # module.compute[0].aws_instance.tenant["bravo-rocky-linux-0"] will be created
  # module.compute[0].aws_instance.tenant["bravo-windows-server-0"] will be created
  # module.compute[0].aws_instance.tenant["training-windows-server-0"] will be created

Plan: 3 to add, 0 to change, 0 to destroy.
```

Notice the naming convention: `{tenant}-{class}-{index}`. Each instance is tagged with its `Tenant` and `Class`, which downstream modules (configuration-management, portal) use for targeting.

---

## Step 4: Understand Where Entitlements Live

Entitlements are declared in `matrix.tenants` within state fragments. The tenants module resolves them into two outputs:

- **`tenants_by_service`**  -  flat list of all tenants mentioning a service (e.g., `["bravo", "training"]` for compute)
- **`tenants_by_class`**  -  per-class tenant lists (e.g., `{ "windows-server" = ["bravo", "training"], "rocky-linux" = ["bravo"] }`)

Consumer modules pull from these outputs. Only modules that create **per-tenant resources** use entitlements:

| Module | Uses entitlements | Why |
|---|---|---|
| compute | Yes | Creates instances per tenant × class |
| archshare | Yes | Creates RDS/ElastiCache per tenant |
| archpacs | Yes | Creates RDS/S3 per tenant |
| configuration-management | No | Global  -  applies to all instances via tags |
| portal | No | Global  -  enabled/disabled via resolver |
| networking | No | Infrastructure-level, no tenant concept |

If a module doesn't consume tenant lists, putting it in entitlements has no effect. Don't add `portal` or `configuration-management` to entitlements  -  their presence in the config is what enables them.

---

## Step 5: Deep Merge and Multi-Fragment Composition

Tenant entitlements are declared as a **map** (keyed by tenant code), which means they survive deep merge correctly. This matters when composing multiple state fragments.

Consider two fragments merged together:

```yaml
# Fragment A: compute-windows.yaml
matrix:
  tenants:
    bravo:
      entitlements: [compute.*]
services:
  compute:
    windows-server: { type: ec2, ami_filter: "Windows_Server-*", count: 1 }

# Fragment B: compute-linux.yaml
matrix:
  tenants:
    acme:
      entitlements: [compute.*]
services:
  compute:
    rocky-linux: { type: ec2, ami_filter: "Rocky-9-*", count: 1 }
```

After deep merge:

```yaml
matrix:
  tenants:
    bravo:
      entitlements: [compute.*]   # From Fragment A
    acme:
      entitlements: [compute.*]   # From Fragment B
services:
  compute:
    windows-server: { ... }   # From Fragment A
    rocky-linux: { ... }      # From Fragment B
```

Both tenants have `compute.*`, so both get both classes. If you want `bravo` to only get `windows-server`, use scoped entitlements: `entitlements: [compute.windows-server]`.

**Key rule**: Tenant codes are map keys, so they stay distinct through merge. Entitlement lists within the same tenant are union-merged (additive). This means two fragments can independently contribute entitlements for the same tenant  -  the result is the union.

---

## Step 6: Target Accounts in top.yaml

To deploy, add your fragment to `top.yaml`:

```yaml
targets:
  '*-platform-dev':
    - regions-east
    - compute-multi-class

  '*-platform-prod':
    - regions-most
    - compute-multi-class
```

Both dev and prod accounts get the same class definitions and entitlements. The environment-specific behavior (regions, instance sizing) can be layered via additional fragments.

---

## Step 7: Commit and Open a Pull Request

```bash
git add platformer/states/compute-multi-class.yaml
git add platformer/top.yaml
git commit -m "PROJ-0000: Add multi-class compute with per-tenant entitlements

- bravo: all compute classes (windows-server + rocky-linux)
- training: windows-server only (scoped entitlement)
- Target all platform accounts"

git push origin your-branch-name
```

Open a pull request. GitHub Actions will run `terraform plan` for each account × region combination and post the results.

---

## Step 8: Run Tests Before Merging

```bash
terraform test
```

Tests validate that:
- State fragments parse correctly
- Tenant × class expansion produces the expected instance count
- Entitlement filtering respects scoped and wildcard entitlements
- Module composition works across fragment combinations

---

## What Just Happened?

1. **Per-tenant infrastructure**: Two tenants sharing an environment but receiving different server configurations
2. **Declarative entitlements**: Tenant-to-class mapping expressed in YAML, resolved automatically by the tenants module
3. **Composable fragments**: Classes and tenants from different fragments merge cleanly via deep merge
4. **No code changes**: Adding a tenant or changing their entitlements is a YAML edit, not a Terraform module change

---

## Key Concepts

### Tenant Entitlements

Entitlements control which tenants receive which per-tenant resources. They live in `matrix.tenants` within state fragments and use dot-notation for scoping:

- `compute.*`  -  wildcard, tenant gets **all** compute classes
- `compute.windows-server`  -  scoped, tenant gets **only** the `windows-server` class
- `archshare`  -  bare service name (for services without class-level scoping)

Services with classes (like compute) use the wildcard `.*` or scoped `.class-name` syntax. Services without classes (like archshare, archpacs) use bare service names.

Entitlements only matter for modules that create per-tenant resources (compute, archshare, archpacs). Globally-scoped modules like portal and configuration-management are controlled by the resolver  -  include their service key in the config to enable them, omit it to disable.

### Tenant Registry

All tenant codes must be registered in `platformer/tenants/tenants.yaml` before they can appear in entitlements. Unregistered or inactive tenants are silently filtered out. This prevents typos from creating orphaned infrastructure.

### Class Expansion

The compute module expands `tenant × class × count` into individual instances. With entitlements, this becomes `entitled_tenants_for_class × class × count`  -  each class only creates instances for its entitled tenants.

### State Fragment Composition

Fragments merge left-to-right with deep merge semantics. Maps merge recursively, lists union-deduplicate. This means:
- Different fragments can contribute different compute classes
- Different fragments can contribute entitlements for different tenants
- The same tenant appearing in multiple fragments gets the union of all entitlements

---

## Best Practices

1. **Use wildcard entitlements for the common case**: If a tenant gets all classes, write `compute.*` not `compute.class-a, compute.class-b, compute.class-c`
2. **Use scoped entitlements for exceptions**: Only scope when a tenant needs a subset of classes (e.g., `compute.windows-server`)
3. **Don't add non-tenant modules to entitlements**: Portal, configuration-management, networking, storage  -  these are globally enabled via the resolver, not per-tenant
4. **Test locally first**: Use `terraform.tfvars` to validate before opening PRs
5. **Check the tenant registry**: New tenant codes must be added to `tenants.yaml` before use

---

## Next Steps

- **Explore archshare/archpacs**: These modules use `tenants_by_service` for per-tenant database and storage provisioning
- **Layer configuration-management**: Add patch management or password rotation fragments alongside compute
- **Create per-environment overrides**: Use `top.yaml` to give dev and prod accounts different fragment sets

In the next document, we'll explore the architectural patterns that make this framework extensible and maintainable.
