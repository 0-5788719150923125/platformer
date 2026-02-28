# Impermanence

In cloud architecture, "ephemeral infrastructure" signals that you understand a fundamental principle: infrastructure should be disposable. Not in theory. In practice. Delete it, recreate it identically, verify it works. If you can't do that, it's not ephemeral - it's permanent, regardless of what you call it.

The word appears in presentations, architecture reviews, strategy documents. Everyone nods. Everyone agrees. But ask what specifically is ephemeral in the system, and you'll discover the word means opposite things to different people. One interpretation creates cattle: disposable, replaceable, identical. The other creates pets: unique, irreplaceable, requiring individual care.

We've been building pets while calling them cattle for years.

## Ephemeral Knowledge, Immutable Vision

Consider what happens to knowledge in task-driven engineering.

An engineer receives a ticket: "Deploy new tenant environment." The task is complex - dozens of variables, networking configuration, security groups, IAM roles, service quotas, tenant-specific requirements. Hours invested understanding context, making decisions, solving problems.

Task completes. Ticket closes. Engineer moves to the next task, equally complex and completely different. The knowledge acquired for the previous task gets discarded to make room. This is necessary - human working memory has limits. You cannot hold dozens of tasks worth of context simultaneously.

The knowledge is ephemeral. Thrown away after use. Not documented because documentation takes time and isn't measured. Not captured in repeatable processes because the process wasn't the deliverable - the deployed infrastructure was.

Meanwhile, new engineers join. They see patterns that don't make sense. They ask: "Why do we do it this way?" They suggest: "At my last company, we did X instead."

The group consensus responds immediately. Not with curiosity. With defense. "That won't work here." "You don't understand our constraints." "We tried that already." The response comes from people who discarded the actual knowledge months ago, operating on assumptions and approximations of what they remember.

The assumptions are immutable. Challenging them requires acknowledging the group might not understand the very definitions of the words they're using. "Ephemeral infrastructure" means what, exactly? Ask three people, get three answers. But questioning the definition means admitting the consensus was built on ambiguity. Easier to shut down the questioner.

This creates a perverse inversion: what should be permanent (knowledge, processes, understanding) is ephemeral. What should be mutable (assumptions, definitions, consensus) is immutable.

## Task-Level vs Architectural-Level Thinking

Senior engineers will insist their infrastructure is ephemeral. They can run `terraform destroy` and `terraform apply` to recreate it. They're not wrong - at the task level.

The problem is scope. They're thinking about one project. One tenant. One deployment. In that narrow context, yes, they can destroy and recreate. The task completes. The mental model holds.

But the architecture isn't one project. It's 500+ Terraform projects with hardcoded references between them. Module paths pointing to specific git refs. State dependencies across projects. Output values consumed as inputs elsewhere. Tenant configurations referencing infrastructure that exists in different state files.

What happens if attacked and everything gets destroyed simultaneously?

**At task level**: "We can rebuild. Run terraform apply."

**At architectural level**: Can't rebuild anything because the dependencies are circular and hardcoded. Project A references outputs from Project B. Project B references modules from Project C. Project C assumes infrastructure exists from Project A. The code that worked before the attack doesn't work anymore because it assumed the rest of the system already existed.

Disaster recovery becomes: figure out which 500 projects to deploy in which order, manually resolve circular dependencies, update hardcoded references that no longer point at valid infrastructure, coordinate across teams who each own fragments, hope someone remembers which manual configurations were required, discover tribal knowledge that was never documented.

This is the cost of ephemeral knowledge. Engineers can only hold one task in their head at a time. So they optimize that task. They make that one project seem manageable, seem testable, seem recreatable. But they never hold the entire system in their head - nobody can. The architectural fragility is invisible at the task level.

Task-level thinking sees `terraform destroy && terraform apply` and concludes "ephemeral infrastructure."

Architectural-level thinking sees 500 interdependent projects with hardcoded references and concludes "house of cards."

When knowledge is ephemeral and vision is immutable, the technical architecture reflects both: fragmented, interdependent, and brittle.

## How This Manifests

Run the deployment generator once per tenant:
```bash
ansible-playbook client_generator.yml \
  -e client_code=newcust \
  -e client_type=sdc \
  -e client_env=prod \
  -e primary_dc=aws \
  -e secondary_dc=nas6 \
  -e patching_status=enabled \
  -e target_jira=PROJ-1234 \
  -e commit_code=true
```

The generator (in `infra-ansible/collections/imsplatform/private_cloud_deployment_generator/`) renders Jinja2 templates into Terraform HCL. Directories appear in `infra-terraform/environment/`. Files materialize. The generated code gets committed to git, and a PR is submitted. Then the generation process stops - never run again for that tenant. The generated Terraform code becomes the canonical infrastructure definition. The templates document what infrastructure *used to be*, not what it *is*.

Six months later, that tenant needs changes. Can't regenerate without overwriting manual modifications. So you modify the generated code directly. Each modification makes it more unique, more permanent. Each of 82 prod tenant environments becomes a snowflake. 14,319 `.tf` files in `environment/`, each a pet requiring individual care.

Testing requires modifying the code with test configurations, deploying, discovering breaks, fixing, then manually reverting all changes before deploying to production. What you test isn't what you deploy. Drift is architectural, not accidental.

Engineers build bash functions to SSM into instances by name because infrastructure lives long enough to need interactive debugging. Infrastructure requiring SSM access isn't disposable - it's permanent.

**The inversion is complete:**
- Generation process: run-once, abandoned
- Generated code: committed, accumulates manual modifications, can't be regenerated
- Infrastructure: unique, irreplaceable, can't be rebuilt without data loss

What should be ephemeral (infrastructure) is permanent. What should be permanent (deployment process) is run-once and abandoned.

## The Operational Test

Can you destroy this environment right now and recreate it identically in the next hour?

**If no**: It's a pet.

**If "theoretically, but we'd need to find someone who knows that tenant"**: Pet.

**If "we'd need to figure out which manual changes were made since deployment"**: Pet.

The only valid answer: "Yes. Run the deployment process. Infrastructure recreates identically from versioned configuration. No tribal knowledge. No coordination. No manual changes to discover."

Everything else is cargo cult cloud-native - vocabulary without principles.

## Why Scale Breaks This

At 40 tenants across 82 prod environments: painful but functional. Changes take weeks. Testing is manual. Disaster recovery is theoretical. But it works. Tasks complete.

At 200+ tenants post-GE Healthcare acquisition: organizational paralysis.

**You cannot scale pets.** Each requires individual care. One hundred pets require one hundred times the effort. Simple changes become multi-week coordination efforts touching hundreds of unique directories. Testing becomes impossible - too many unique configurations to verify. Disaster recovery becomes theoretical - too much tribal knowledge required. Changes become paralyzed - coordination cost exceeds value.

**Cattle scale.** Pattern-based targeting: `'*-prod'` matches all production. Configuration change in one state fragment applies everywhere. Test once, deploy everywhere identically.

The generation process is run-once. The generated code becomes permanent. The infrastructure becomes permanent. At current scale: expensive. At future scale: catastrophic.

## No Checks, No Balances

While writing this, the team is on a conference call with Tailscale. Not to fix the fundamental issue - all tenants share a single tailnet, security depending on ACL maintenance that's been broken for 3 years. They're discussing how to create one test tailnet.

This is the pattern: address symptoms, ignore root causes.

**The problem**: Tenant networks should be structurally isolated via separate tailnets. ACL-based isolation in a shared tailnet is configuration theater - works until the configuration is wrong, which it has been for years.

**What should happen**: Migrate to per-tenant tailnets. Structural isolation. Tenant A cannot reach Tenant B because they exist in different networks.

**What is happening**: Build a test tailnet. Leave production architecture broken. Continue sharing a single tailnet across all tenants. Continue not maintaining ACLs. Build infrastructure to work around the broken architecture instead of fixing it.

Recent example: Engineers have spent months swatting flies around a flaming trash heap we call "Kubernetes" - migrating to pod identity, bumping EKS module versions, reconciling drift. No authorization. No impact assessment. No testing framework. Just changes applied because senior engineers had authority to do it. Meanwhile, fundamental architectural deficiencies remain unaddressed. Infrastructure is production. Change process is ad-hoc.

This is what happens when organizational structure prevents architectural oversight and immutable assumptions prevent questioning.

## What Should Be Permanent vs Ephemeral

**Should be permanent:**
- Deployment processes (run repeatedly, produce identical results)
- Testing frameworks (validate before deploy)
- Configuration definitions (versioned, composable, testable)
- Knowledge (captured in processes, not discarded after tasks)

**Should be ephemeral:**
- Running infrastructure (disposable, replaceable)
- Deployed instances (destroy and recreate at will)
- Tenant environments (cattle, not pets)

**Should be mutable:**
- Assumptions (challengeable when wrong)
- Definitions (refinable when ambiguous)
- Consensus (updatable with new information)

We inverted all three.

## The Alternative

Platformer demonstrates permanent processes creating ephemeral infrastructure. Same engineers. Same AWS. Different principles.

**Deployment process:**
- State fragments define configuration: `services.compute.instances.redis.count = 2`
- Pattern-based targeting: `'*-platform-dev'` matches all dev accounts
- Composable: fragments merge to create complete configuration
- Testable: `terraform test` validates before commit
- Repeatable: same YAML + same modules = same infrastructure

**Infrastructure lifecycle:**
- Deploy: `terraform apply` from state fragments
- Test: same code, different credentials (`AWS_PROFILE=dev`)
- Update: modify state fragment, `terraform apply`
- Destroy: remove configuration, `terraform apply`
- Rebuild after disaster: state fragments still exist, `terraform apply`

The artifact tested is byte-for-byte identical to the artifact deployed. No generators run once. No code committed and forgotten. No manual modifications creating drift. No test configurations to revert before production.

**Measured outcomes:** Hours instead of weeks. Zero coordination. Testing validates production configuration. Disaster recovery is deterministic.

Not theoretical. Operational. Managing real infrastructure.

## The Question

When infrastructure is called "ephemeral," which layer is actually ephemeral?

If the generation process is run-once and the generated code becomes permanent, you're building pets regardless of terminology. At 40 tenants: expensive. At 200+ tenants: impossible.

If the deployment process is permanent and repeatable, and infrastructure is ephemeral and disposable, you're building cattle. Scales linearly. Changes apply uniformly. Testing validates reality.

The organization can acknowledge the inversion and address it. Or continue using the word "ephemeral" in presentations while building increasingly permanent, increasingly irreplaceable, increasingly fragile infrastructure - until scale forces catastrophic recognition that the most fundamental term in the architecture meant the opposite of what was implemented.

The generation process is run-once and abandoned. The generated code becomes permanent and drifts from its templates. The infrastructure becomes permanent and irreplaceable. Knowledge is ephemeral. Vision is immutable.

Why are we building it backwards?