# Module Composition and Architecture Patterns

**User Story**: *As a platform architect, I am expected to build maintainable systems that scale gracefully and minimize coupling between components.*

This document provides an overview of the architectural patterns used in Platformer. It's intentionally high-level - the goal is to help you understand *why* the system is structured this way, not to provide exhaustive implementation details.

---

## Core Architectural Patterns

This framework is built on three key patterns:

1. **Module Composition**: Services are composed from small, focused modules
2. **Dependency Inversion**: Modules communicate via interfaces, not direct coupling
3. **Conditional Creation**: Infrastructure activates only when needed

These patterns are drawn from HashiCorp's module composition guidance: https://developer.hashicorp.com/terraform/language/modules/develop/composition

---

## 1. Module Composition

Traditional Terraform modules often try to do too much. They become monolithic, difficult to test, and hard to extend. Or, modules become too focused, and too specialized - often reimplementing resources that were already isolated (i.e. an 'aws-iam' module that implements AWS IAM features, or an 'aws-ec2' module that implements EC2 provisioning.)

This framework takes a different approach: **each module implements a dedicated service**, and the root orchestrator (`main.tf`) composes them into complete systems.

### Example: Configuration Management

The `configuration-management` module handles:
- SSM document discovery and deployment
- State Manager associations
- Patch baselines and maintenance windows

It does **not** handle:
- Creating instances (that's `compute`)
- Creating S3 buckets for logs (that's `storage`)
- Determining which instances to target (that's provided by the caller)

This separation allows you to:
- Test modules in isolation
- Reuse modules in different contexts
- Swap implementations without affecting consumers

### Where to see this in practice:

Look at `platformer/main.tf` to see how modules are wired together. Notice how each module has a clear interface (inputs and outputs) and limited scope.

---

## 2. Dependency Inversion

One of the most powerful patterns in this framework is **dependency inversion**: modules don't directly depend on each other. Instead, they communicate via interfaces defined by the root orchestrator.

### The Problem with Direct Dependencies

Traditional approach:
```
compute module → queries → storage module for bucket name
```

This creates tight coupling. If you change the storage module, the compute module breaks.

### The Dependency Inversion Solution

New approach:
```
compute module → outputs → "I need a bucket"
root orchestrator → connects → compute to storage
storage module → outputs → "Here's a bucket"
```

Now modules are independent. You can:
- Test the compute module without deploying storage
- Replace the storage module with a different implementation
- Deploy compute without storage (it simply disables features that need buckets)

### Where to see this in practice:

Look at `platformer/main.tf` around lines 40-60. Notice how:
- The `compute` module outputs `instance_parameters` (a list of parameters it needs created)
- The root orchestrator passes this to the `configuration-management` module
- The `configuration-management` module creates SSM parameters based on the request

Neither module directly depends on the other. The root orchestrator is the only place that knows about both.

---

## 3. Conditional Creation

Infrastructure should only exist when it's needed. This framework uses the `count` pattern to conditionally enable entire modules.

### Example: Storage Module Auto-Enabling

```hcl
module "storage" {
  count = local.storage_needed ? 1 : 0
  # ...
}

locals {
  storage_needed = (
    length(module.configuration_management[0].bucket_requests) > 0 ||
    var.config.storage.enabled
  )
}
```

This means:
- If `configuration-management` needs a bucket, `storage` automatically activates
- If no one needs storage, it doesn't deploy (no unused resources)
- If you explicitly enable storage, it deploys regardless

### Benefits:

- **Cleaner plans**: Only see resources that are actually being used
- **Lower costs**: Don't pay for unused infrastructure
- **Easier reasoning**: If a module is in the plan, it's there for a reason

### Where to see this in practice:

Look at `platformer/main.tf` around lines 20-30. Each module has a `count` expression that determines whether it should be created.

---

## Practical Implications

### Creating a New Module

If you wanted to add a new service (e.g., `monitoring`), you would:

1. **Create the module**: `platformer/monitoring/main.tf`
2. **Define the interface**: What inputs does it need? What outputs does it provide?
3. **Add conditional creation**: `module "monitoring" { count = local.monitoring_needed ? 1 : 0 }`
4. **Wire it in**: Connect outputs from other modules to monitoring's inputs
5. **Add state fragments**: Create `states/monitoring.yaml` for configuration

The key insight: **you modify `main.tf` to wire things together**, but the module itself remains independent.

### Testing Modules

Because modules are loosely coupled, you can test them in isolation:

```hcl
# tests/monitoring.tftest.hcl
run "basic_monitoring" {
  variables {
    instances = {
      "test-instance" = { id = "i-12345" }
    }
  }

  assert {
    condition = length(aws_cloudwatch_alarm.instance) == 1
  }
}
```

No need to deploy the entire stack - just the module you're testing.

### Evolving the Architecture

As requirements change, you can:
- Replace modules without affecting others (loose coupling)
- Add new modules without modifying existing ones (open/closed principle)
- Reorganize module responsibilities by changing wiring in `main.tf`

---

## Further Reading

- **HashiCorp Module Composition Guide**: https://developer.hashicorp.com/terraform/language/modules/develop/composition

  Essential reading. Covers patterns for input variables, output values, and module composition strategies.

- **Root Orchestrator (`main.tf`)**: `/home/rybrooks/infra-terraform/platformer/main.tf`

  Read this file to see how modules are wired together. Pay attention to:
  - How `count` controls module creation
  - How outputs from one module become inputs to another
  - How locals compute whether modules are needed

- **Individual Module Interfaces**: Look at each module's `variables.tf` and `outputs.tf`

  These define the "contract" each module expects and provides.

---

## TODO: Expand This Document

This is a stub. Future sections could include:

- **Detailed walkthrough of main.tf wiring**: Step-by-step explanation of how modules connect
- **Creating a new module from scratch**: Full example with tests, state fragments, and integration
- **Advanced pattern matching in top.yaml**: Salt-style compound targeting examples
- **Module versioning and stability**: How to evolve modules while maintaining backward compatibility
- **Performance considerations**: How to optimize plan/apply times in multi-account deployments
- **Debugging techniques**: How to troubleshoot issues in the orchestration layer

**If you're interested in contributing to this document**, focus on practical, concrete examples. Our audience is experienced Terraform engineers who are skeptical of new approaches - show them working code, not abstract theory.

---

## Closing Thoughts

These patterns - module composition, dependency inversion, and conditional creation - are not new. They come from decades of software engineering experience, adapted for Terraform's declarative model.

The goal is not to be clever. The goal is to be **maintainable**:

- When requirements change, you modify configuration (YAML fragments), not code
- When you add new services, you compose modules, not rewrite them
- When you deploy, the system automatically figures out dependencies

If you're coming from the old `environment/*` structure, this will feel unfamiliar at first. That's expected. Give it time. Run through the examples. Once the patterns click, you'll find this approach significantly more flexible than per-directory deployments.

**Questions or suggestions?** Ask Platform Architecture. This framework evolves based on feedback from engineers using it in production.
