# Foundations

The README says what Platformer is and how to run it. This is why it's shaped the way it is, and where the ideas came from. Most of them were borrowed: from GitOps, from HashiCorp's own guidance, from AWS, from distributed databases, from neural networks, and from the Twelve-Factor App. What's ours is the combination.

## The Shape

Platformer orchestrates at the level of accounts and regions, out of modular services, controlled by fragments. Four principles hold it together:

- **Service-level grouping.** Each module is a service (configuration management, compute, storage), not a resource type.
- **A single state per account and region.**
- **Fragments as configuration.** YAML fragments in Git decide what runs where (GitOps).
- **Module-owned defaults.** A module knows its own sensible defaults; fragments only say what's different.

## Dependency Inversion

Some modules provide infrastructure (buckets, instances) that other modules consume. Instead of coupling them, Platformer inverts the dependency. Consumer modules declare what they need through outputs (`bucket_requests`, `instance_parameters`). The root module (`main.tf`) notices those needs and switches on the modules that provide them. The providers (storage, compute) fulfill requests without anyone referencing them directly, and nobody has to configure them by hand.

Modules don't know about each other, so they stay decoupled. Providers turn on when something needs them, with no manual orchestration. Requests and responses follow standard shapes, so new consumers and new providers fit in without rewiring the old ones. [present/05-dependency-inversion.md](../present/05-dependency-inversion.md) draws it out with diagrams, and [learn/3-module-composition.md](../learn/3-module-composition.md) walks through it in code.

## Many Accounts, One Codebase

In CI, GitHub Actions deploys to many accounts and regions from composable fragments. Accounts are discovered through AWS Organizations (`organizations:ListAccounts`). Reusable fragments live in `fragments/` (or outside the repo, through `fragment_paths`; see [fragments/README.md](../fragments/README.md)). `top.yaml` maps account patterns to fragments, in the spirit of Salt's top file:

```yaml
targets:
  '*-platform-dev':
    - regions-east
    - configuration-management
```

Fragments merge left to right, and `matrix.regions` fans each account out into one parallel deployment per region.

## GitOps

[Atlassian - What is GitOps?](https://www.atlassian.com/git/tutorials/gitops)

Git is the single source of truth: all infrastructure is declared in version control, and nothing changes by hand in a console. Configuration is declarative, pure Terraform with services switched on by YAML fragments. Deployment is automated from Git commits; push-based delivery suits cloud infrastructure. Every change has a history and goes through a pull request.

The targeting borrows from [SaltStack's top file](https://docs.saltproject.io/en/latest/topics/tutorials/states_pt1.html). Pattern matching in `top.yaml` (`'*-platform-dev'`, `'*dev*'`), combined with composable fragments (`configuration-management`, `regions-east`), targets deployments across many accounts and regions without a directory per environment.

## Module Composition

[HashiCorp - Module Composition](https://developer.hashicorp.com/terraform/language/modules/develop/composition)

The module hierarchy is flat, a single level of child modules, for simplicity. (The per-cloud adapters inside a service, such as `compute/aws/` and `compute/oci/`, are the one deliberate exception; [fully-connected.md](fully-connected.md) explains why.) Modules receive their dependencies as inputs rather than creating them: the root derives `aws_account_id` and `namespace` once and passes them down. Each module represents a service, not an individual resource.

## Multi-Region State

[AWS - Multi-Region Terraform Deployments with AWS CodePipeline](https://aws.amazon.com/blogs/devops/multi-region-terraform-deployments-with-aws-codepipeline-using-terraform-built-ci-cd/)

There is one state file per account and region, keyed `pt-terraform/platformer/{account_id}/{region}.tfstate` for isolation. A GitHub Actions matrix runs one deployment per account and region in parallel. IAM policies are inline, which avoids the limit of 10 attached policies per role while keeping deployments per region.

## Eventual Consistency

[GUN Database - Conflict Resolution with Guns](https://gun.eco/docs/Conflict-Resolution-with-Guns)

Platformer embraces eventual consistency as a design principle, in the spirit of distributed databases like GUN. Rather than chase perfect synchronization, the system converges toward a consistent state through repeated reconciliation.

Repeated `terraform apply` runs converge infrastructure toward the declared state, absorbing transient failures and dependencies along the way. Scheduled SSM associations run again and again (every 30 minutes, say), so compliance arrives eventually even when a single run fails. Every operation is idempotent and safe to repeat: SSM documents generate fresh passwords each run, and IAM policies converge to what's declared. Infrastructure drifts back toward the desired state without anyone stepping in. Wildcard targeting (`InstanceIds = ["*"]`) brings new instances into the next cycle automatically.

This trades strict consistency for availability and partition tolerance (the CAP theorem). A system that's briefly unreachable, or that fails an operation, reaches the desired state on a later cycle. It finds its balance through continuous reconciliation, not perfect coordination.

## One State, Not Fragments

[Microsoft Learn - Deep Learning Concepts](https://learn.microsoft.com/en-us/azure/machine-learning/concept-deep-learning-vs-machine-learning)

Platformer moved from sparse connectivity to fully connected infrastructure management, which maps neatly onto neural network design.

The legacy approach (`environment/*`) fragmented state across many directories and state files, and needed orchestration tools like Atlantis to hold it together. Each deployment worked with partial information about the organization, like a sparse network where "neurons in one layer connect only to a small region."

The current approach (`platformer/*`) has one state, in the sense that every deployment converges toward the same configuration manifest. Each Terraform run has the whole organization in view, through `top.yaml` pattern matching and the AWS Organizations API, like fully connected layers where "each layer is fully connected to all neurons in the layer before it." State files are still scoped per account and region for isolation, but every run reads the same codebase, the same configuration system, and the same view of the organization.

Full connection enables what fragments can't: pattern matching across accounts, one deployment of a service everywhere, reconciliation across the organization. Like training a network with the complete gradient rather than partial derivatives, one unified state lets the system make better decisions.

Terraform is, underneath, a deeply nested graph computation that resolves dependencies between resources. The more of the graph one run can see, the better it handles hard operations: migrations, reordering dependencies, refactoring state. Fragmented state limits what Terraform can see, which forces people to coordinate by hand the changes it could have resolved on its own. [fully-connected.md](fully-connected.md) takes this idea across clouds.

## Twelve-Factor Infrastructure

[The Twelve-Factor App](https://12factor.net/)

The twelve factors were written for applications, but most of them apply directly to infrastructure. Four of them separate declarative, service-oriented infrastructure from the traditional kind.

**III - Config.** Everything environment-specific lives in external fragments (`fragments/*.yaml`), never hardcoded in modules. The same module code deploys to every account and region with different configuration, so there are no per-environment codebases and behavior is consistent everywhere.

**IV - Backing services.** Services (configuration management, compute, legacy) are attached resources, switched on and off purely through fragments. Because modules load conditionally, components attach and detach without code changes, the way an app swaps databases through an environment variable instead of a hardwired dependency.

**IX - Disposability.** Modules attach and detach quickly and cleanly. The `legacy` module shows it: a whole Atlantis deployment can be switched on, used, and removed completely by changing configuration, with no orphaned resources and no manual cleanup. Treating components as cattle, not pets, makes experiments safe and rollbacks fast.

**X - Dev/prod parity.** Developers run exactly the code that CI runs in production, loading the same YAML fragments through the `config` module. Setups that keep development and production in separate directory trees leave gaps where "works on my machine" thrives. Here, the only difference between environments is which fragments load and which `aws_region` is targeted.

Moving from directories per environment to services that load by configuration is infrastructure as code growing into the principles that changed application architecture. Services become composable, environments become configuration, and deployments become deterministic.
