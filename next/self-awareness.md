# Self-awareness

Most of the documents in this directory point outward -- at organizational patterns, at legacy architecture, at leadership gaps. This one points inward.

Platformer is not finished. It is not perfect. It carries its own brittle patterns -- decisions that were expedient at the time, shortcuts that became load-bearing, assumptions that hardened into dependencies. Some of these are known and tolerated. Others are the kind of thing you don't notice until something breaks in a way you didn't expect.

This document catalogs the ones we can see. Not to apologize for them, but to name them -- because naming a problem is the first step toward someone solving it. Maybe you.

---

## Hardcoded Provider Profiles

`platformer/providers.tf` defines two cross-account AWS providers with hardcoded profile names:

```hcl
provider "aws" {
  alias   = "prod"
  region  = "us-east-2"
  profile = "example-platform-prod"
}

provider "aws" {
  alias   = "infrastructure"
  region  = "us-east-2"
  profile = "example-infrastructure-prod"
}
```

These exist because Platformer needs to reach into other accounts -- to replicate secrets from `example-infrastructure-prod`, to read shared resources from `example-platform-prod`. The need is real. The implementation is brittle. Anyone who doesn't have these exact profiles configured in their AWS credentials cannot run `terraform plan` without errors. The framework becomes non-portable the moment you try to use it outside our specific AWS organization.

There might be a better pattern here. A variable that accepts a list of profiles, where each aliased provider indexes into the list and conditionally disables itself if no profile exists at that position. Or a map of provider aliases to profile names, with sensible defaults that degrade gracefully. The profiles would be user-defined rather than organization-specific, and Platformer could operate in any AWS environment without touching `providers.tf`.

**The question:** How do we give modules cross-account access without welding the framework to our specific account topology?

---

## Shell Script Brittleness

Platformer relies on shell scripts throughout its modules. Helm deployments, kubeconfig management, Docker Compose orchestration, Kubernetes secret creation, git archive generation, markdown link processing -- all implemented in Bash via `local-exec` provisioners or `external` data sources.

Shell scripting is fast to write and universally available. It is also the source of our most frustrating debugging sessions. The `awk` versus `gawk` discrepancy between macOS and Linux cost us time we didn't need to lose. Different default shells, different coreutils versions, different `sed` flavors -- each is a hairline fracture waiting for the right conditions to become a break.

The `auto-docs` module already moved to Python for exactly this reason. Its HCL parser and documentation generator are more robust, more testable, and more readable than the Bash-and-AWK approach they replaced. The precedent exists. The question is whether we extend it.

Not everything needs to move. Simple one-liners in `external` data sources -- a `git rev-parse` here, an `echo` there -- are fine as shell. But the multi-page scripts that manage Helm releases, process markdown, orchestrate Docker Compose, and create Kubernetes secrets? Those are doing real work with real error handling, and they'd benefit from a language that doesn't break when someone's `PATH` is different.

**The question:** Which scripts hurt the most, and who wants to port them?

---

## Invisible Prerequisites

Platformer's SSM capabilities -- session management, patch management, Run Command, the entire configuration-management module -- depend on Default Host Management Configuration (DHMC). DHMC is what automatically enrolls EC2 instances into Systems Manager without requiring an instance profile or manual agent registration. It is foundational. Without it, instances are invisible to SSM.

Platformer didn't deploy DHMC. It was deployed from `environment/prod/org-root/aws-cloudformation` -- a CloudFormation stack in a completely separate project, managed by a different workflow, with no dependency link back to Platformer. The stack creates an IAM role (`AWSSystemsManagerDefaultEC2InstanceManagementRole`), an automation document, and an association that enables the DHMC service setting. Platformer assumes all of this exists. It has to -- DHMC is an account-level setting, not a per-deployment resource. But the assumption is silent. Nothing in the framework validates that DHMC is enabled. Nothing warns you if it isn't. You deploy instances, they don't appear in SSM, and you spend an hour figuring out why before someone remembers that DHMC was set up by hand six months ago.

This is the difference between having an opinion and making an assumption. Platformer can have an opinion that DHMC is the right approach to SSM enrollment -- that opinion is well-founded. But it should not assume that DHMC is already configured in whatever account it's deployed to. If the framework is ever open-sourced, or deployed to a new account, or handed to someone who wasn't in the room when DHMC was set up, this invisible prerequisite becomes an invisible failure.

The fix might be a validation check -- a data source that reads the SSM service setting and fails with a clear message if DHMC isn't enabled. Or it might be a bootstrap module that can deploy DHMC itself when needed. Or it might just be documentation that makes the dependency explicit. But right now it's none of those things. It's tribal knowledge.

**The question:** Should Platformer own its prerequisites, or is it enough to document them -- and if we document them, where does someone who's never seen the framework actually find that documentation?

---

## Image Build Strategy

The compute module supports golden AMI builds through a `build: true` flag on EC2 classes. The original implementation used AWS ImageBuilder, which was subsequently replaced with Packer. Packer is cloud-agnostic -- it builds AMIs, Azure Managed Images, GCP Images, VMware templates, and Docker containers from the same template language. The migration resolved the original brittleness (ImageBuilder welded to AWS), but `build` is still a boolean. It says *whether* to build, not *how*.

If the multi-cloud vision described in these documents materializes, a single class may need to produce images for multiple platforms simultaneously -- an AMI for AWS and a VMware template for on-premises, from the same source definition. The boolean doesn't encode that. Packer itself supports multi-builder configurations natively, but the compute module's interface doesn't expose that capability yet.

```yaml
classes:
  rocky-linux:
    build: true              # Current: Packer, AMI only
  windows-server:
    build: [ami, vmware]     # Future: multiple targets from one source
```

**The question:** When we extend `build` beyond a boolean, do we route on a single string, or do we anticipate needing multiple build targets for the same class?

---

## Glass Cannon

Platformer is extremely powerful. A single commit to master can deploy infrastructure across every account in the organization. `top.yaml` targets accounts by pattern. Modules are unversioned -- every account gets the same code at the same time. State fragments compose into a unified configuration that renders identically everywhere it's applied. This is the design. It's what makes continuous reconciliation possible, what makes drift detection instant, what makes security fixes propagate in hours instead of weeks.

It is also what makes a bad commit catastrophic.

There is no version pin between accounts. There is no canary deployment where staging gets the change first and production gets it next week. There is no multi-branch strategy where `dev` runs ahead and `prod` lags behind. One branch. One commit. Every account. If that commit contains a destructive change -- a misconfigured `for_each` that drops resources, a state fragment typo that removes a service, a module refactor that changes resource addresses -- the blast radius is the entire fleet.

There are two ways to think about this.

The first is principled design. If infrastructure is built to survive destruction -- compute instances are disposable, state is bound to durable storage, data lives in S3 and RDS with lifecycle protections, volumes can be reattached, secrets are replicated, AMIs are golden -- then accidental blasts are recoverable. You rebuild from the same code that destroyed, because the code is correct and the data survived. This is the philosophy Platformer was designed around: cattle not pets, immutable infrastructure, the assumption that anything compute-shaped can be recreated from its declaration. If the declaration is right and the data layer is durable, recovery is fast. The blast radius is wide but shallow.

The second is versioned orchestration. Different environments pin to different points in time -- production runs last week's code, staging runs yesterday's, dev runs HEAD. Or different branches serve different scopes. Or a separate repository manages production deployments with its own merge cadence. This creates a buffer between change and consequence. It also creates the exact problem that Platformer was built to eliminate: fragmented code, version drift, environments that diverge silently, coordination overhead that scales with the number of branches and repos and owners. This is what `environment/*` looks like today across the organization -- and the complexity it produces is well-documented in other files in this directory.

There is a middle ground: version pinning within `top.yaml` itself. Targets could optionally declare a commit hash or tag, and the CI pipeline would checkout that ref before running Terraform for those accounts. Production pins to last week's tag. Staging runs HEAD. The same code, the same repo, the same branch -- but specific accounts lag behind by design. This avoids the multi-branch fragmentation while still creating a buffer between change and consequence. The cost is additional logic in the pipeline to handle per-target checkouts, and the discipline to promote tags forward on a regular cadence so pinned accounts don't drift indefinitely behind.

The first approach is still better. It demands more discipline -- every resource must be designed for survivability, every data layer must be durable, every module must be idempotent -- but it produces a system that is both powerful and recoverable. The second approach is safer in the short term and more fragile in the long term, because the complexity it introduces is the same complexity that made the old architecture uninterpretable. The third is a pragmatic hedge -- useful while modules are still maturing toward full survivability, removable once they get there.

But the first approach only works if we actually follow it. If a module creates an EBS volume without lifecycle protection, if a database is provisioned without deletion protection, if state is stored without backup -- then the glass cannon has no armor, and a bad commit doesn't just destroy infrastructure. It destroys data.

**The question:** Are we building every module with the assumption that it will be destroyed and recreated? And if not -- which modules aren't there yet, and what would it take to get them there?

---

## The Machine Commitment

This one isn't brittle in the way the others are. The hardcoded profiles will break when you move to a new org. The shell scripts will break on the wrong OS. Those are fractures waiting to happen. This is different. This is a load-bearing decision that works *because* of what it demands -- and what it demands is a permanent shift in how the framework is maintained.

Platformer was built with AI. Not as a novelty, not as an experiment, but as the primary implementation layer. The abstractions -- dependency inversion across modules, dynamic block generation from deeply nested config objects, `for_each` expressions that flatten heterogeneous maps into resource instances, provider functions composing merged state at plan time -- these are patterns that a language model can navigate fluently and that a human reads with effort. The framework is easy to *reason about* (state fragments in, infrastructure out, deterministic and testable) but hard to *read* in the way that a simple `aws_instance` block with five arguments is readable.

This is [the trade-off at the heart of the design](./thinking-machines.md): Terraform is a functional language with a declarative DSL, and functional languages are notoriously difficult for humans to read because the execution flow is emergent, not explicit. Platformer leans into that. It optimizes for the dependency graph, for the merge operation, for the patterns that the Terraform engine and AI tooling both handle natively. It does not optimize for a human opening `compute/main.tf` and immediately understanding every resource that will be created from a given configuration.

The old code in `environment/*` optimizes the other way. Every resource is explicit. Every account has its own directory. Every value is hardcoded where it's used. A human can open any file and understand it in isolation. The cost is that no human can hold the whole system in their head -- 536 `main.tf` files, each readable, collectively incomprehensible. Platformer inverts this: the whole system is comprehensible (state fragments compose into infrastructure), but the individual modules require fluency in patterns that most engineers haven't internalized.

This is not a fragility in the traditional sense. The code doesn't break. The abstractions don't fail. But the framework has made a commitment: it assumes that AI-assisted development is a permanent part of the workflow. Not optional. Not supplemental. Foundational. The patterns were chosen because they align with how language models generate and reason about code. The velocity -- hours instead of weeks -- comes from that alignment. Remove the AI from the workflow, and a human maintaining these modules needs to hold functional composition, implicit dependency chains, and dynamic resource generation in working memory simultaneously. It can be done. It is not easy. And it gets harder as the framework grows.

This is worth naming honestly, because it cuts both ways. The commitment to AI-assisted development is what makes Platformer possible at all -- no team of humans could build and maintain these abstractions at the speed required to keep pace with 127 accounts and growing. But it also means the framework's long-term maintainability is coupled to the continued availability and capability of AI tooling. If the tools improve, the framework gets easier to extend. If the tools regress or disappear, the framework becomes an artifact that works but resists modification by the humans left holding it.

The bet is that AI tooling will improve. That bet looks good today. But it is a bet, and this document is about naming the things we're depending on.

**The question:** How do we keep Platformer's abstractions accessible to humans who are learning, without sacrificing the functional patterns that make it powerful? Is that auto-docs' job? Is it SCHEMA.md's job? Is it a job for better inline documentation of *why* a pattern exists, not just *what* it does? Or do we accept that fluency in these patterns is now a professional requirement, the same way fluency in SQL or networking was a requirement in previous eras?

---

## What Else?

These are the brittle bones we can see. There are certainly others -- patterns that feel solid today but will crack under the weight of the next requirement, the next region, the next team member who tries to run the framework on a machine we didn't anticipate.

If you've hit something brittle that isn't listed here, add it. This document is a living inventory of the things we know need attention. Not a backlog. Not a sprint item. Just an honest list of where the framework is weaker than it should be, maintained by the people who use it and know where it hurts.

Platformer's strength is that it evolves. These are the places it needs to evolve next.
