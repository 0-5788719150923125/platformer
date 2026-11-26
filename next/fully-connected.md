# Fully Connected

## The Second Cloud

For most of its life, Platformer has spoken one language.

That was never the plan. The vision in `multi-cloud.md` reached for every cloud at once: AWS, Azure, GCP, on-premises, the edge, all managed through a single operational model. Its own appendix was more honest: multi-cloud provider support, partial, AWS primary. The framework grew up with access to one cloud, so one cloud's words filled every gap.

Then Oracle arrived. Two small machines on Oracle's free tier, registered with AWS Systems Manager through hybrid activations, patched on Platformer's schedule, with a compose stack written and waiting to deploy to them. Platformer already managed them. It just didn't own them. The next step looked small: let Platformer create them too. Add the Oracle provider, write a module, import a network.

The first experiment didn't touch Oracle at all. It asked a simpler question: if someone clones Platformer and only uses one cloud, can they still run it?

The answer was no, and not because of Oracle. Platformer already failed that test with AWS. A user with no AWS credentials could not produce a plan, even with every AWS module switched off. The root variable promises "Set to null to disable AWS (for local dev without credentials)." Nobody had ever tested that promise without AWS credentials, because everyone who had ever run Platformer had them.

That failure is where this story begins, because it isn't a bug in a module. It's a property of the kind of graph we build.

## Sparse and Dense

Most Terraform in the world is sparse.

It lives in many small roots, each owning a fragment: a network in one repository, a cluster in another, DNS in a third. The fragments connect through remote state lookups, naming conventions, wiki pages and people. Each root mentions only the providers it needs, so each root looks simple. The complexity hides in the connections between them, and those connections aren't in any graph. When the network changes, the cluster finds out on its next run, or during the next incident.

Platformer is dense. One root, every service module wired into it, every module able to see every other module's outputs. A storage request from arcbot, a patch baseline in configuration management, a subnet in networking: one graph, one plan. When something changes, the plan shows everything it touches.

In the language of neural networks, it's the difference between a stack of separately trained models glued together with scripts, and a single fully connected network where a change flows through every edge it should. The plan is our forward pass. Every reference is an edge that carries consequence.

That density is the niche. Terraform's authors built a language that can describe an entire estate as one connected whole. In practice, almost nobody builds that way. The tooling, the tutorials and the folklore all point toward fragments. Platformer is a bet that the fragments are an accident of habit, not a law of nature.

But density has a cost, and the second cloud is where we found it.

## The Input Layer

Before Terraform evaluates a single resource, it sets up its providers: the plugins that know how to talk to AWS, to Oracle, to Azure. Every provider mentioned anywhere in the configuration gets set up, whether or not anything will use it. A module switched off with `count = 0` still declares its resources, those resources still name their provider, and so the provider still gets set up. Set up means authenticated, or at least sent looking for credentials.

In a sparse world, nobody notices. Each small root mentions only what it uses. In a dense world, the providers form an input layer shared by the whole network: the union of every cloud the framework has ever learned. Every user pays for every cloud. Teach Platformer to speak Oracle, and every user without an Oracle account is locked out. Teach it Azure, and it happens again.

We tried to make the input layer flexible, and Terraform said no. A provider block cannot be repeated or switched off with `for_each`. The word is reserved, in Terraform's own error message, "for use by Terraform in a future version."

We read that as deliberate. Providers are the ground the graph stands on. A provider whose existence depended on something computed inside the graph would mean planning against ground that isn't there yet. The people who designed Terraform made the input layer static and left a marked door for later. We'll design as if that decision is sound, because it probably is.

## Three Doors We Didn't Take

The first door was to lie to the input layer. Give every unused provider harmless stand-in credentials, enough to satisfy its setup without ever reaching its cloud. It works when a provider makes no network call during setup. AWS, Oracle and Google all accepted stand-ins. Azure didn't: it logs in to Microsoft while it sets up, and no fake survives a real login. Port's provider changed from one behavior to the other between versions. A placeholder is a treaty with each provider's internals, and the provider can rewrite its half of the treaty in any release. We'll still use one for AWS as a stopgap, but it can't be the architecture.

The second door was the most tempting: break the graph. Run each cloud as its own Terraform, called from a thin parent that only decides which children to run. It's how our own module tests already work. But tests can break the graph because a test changes nothing anybody needs to approve. Infrastructure is the opposite. The moment one Terraform calls another, the plan the human reads stops being the plan that runs: the parent sees a command, not a change. Cross-cloud references, like an Oracle machine that needs an AWS activation code to register itself, become files passed between processes and ordered by hand. It's a gradient stopped at the boundary. That is exactly the sparse world we exist to leave, rebuilt inside our own repository.

This door is also how most of the industry became sparse in the first place, usually without meaning to. A team hits a provider problem: a second account, a second region, a provider that can't be switched off. They search for help, and the help they find is tooling that runs Terraform many times instead of once. Atlantis is the best known. It watches pull requests, finds every directory a change touches, and runs a separate plan and apply for each one. Teams split their estate into more and smaller roots to fit it, and the result gets written up as best practice. But each of those plans is computed alone. When one root's outputs feed another, the second plan is drawn against the first root's old state, before the change that will alter it has been applied. No single plan shows the whole consequence of a change, and that is the guarantee Terraform's plan was built to give. And because Atlantis applies from the pull request before it merges, the main branch only describes what's running if every apply succeeded and every pull request was merged afterward. The tool works, but it works in the gaps between graphs, gaps the fragmentation created. Platformer still carries a module called `legacy` that deploys Atlantis as disposable cattle, a reminder of the fragmented world it grew out of.

The third door was to change engines. OpenTofu, the community fork of Terraform, already allows `for_each` on providers, and in a scratch test it did exactly what we needed: an unused cloud got no provider at all. People reasonably ask why we don't just switch. The answer is built into what Platformer is for. This project exists to test whether Terraform can hold an entire estate, across clouds, in one connected graph. Changing engines the moment Terraform made that hard would mean abandoning the experiment instead of running it. There's a second reason, too. Terraform was designed by people who spent years on exactly these problems, and a capability they've reserved by name looks like a deliberate decision about sequencing, not an oversight to route around. If they open that door, we'll walk through it, and the proxy described below can retire. But waiting isn't a plan either. The multi-cloud claim is ours to test now, on the engine we set out to test.

## Call by Need

Our first answer was to choose the architecture before the forward pass. A neural network's architecture is fixed before training begins; nobody adds a layer halfway through. Terraform has the same split: the set of providers is architecture, and everything else is computation. So we built a small step that ran before Terraform, read which clouds a workspace declared, and assembled the configuration for exactly those clouds.

It worked, and it was wrong. The step lived outside the graph, so it had to run again every time someone switched workspaces, and every plan depended on whether it had. A guard could catch a forgotten run, but the guarantee had moved out of Terraform and into a habit. That was the second door again, only smaller.

The answer came from the other side of computer science: lazy evaluation. A lazy language doesn't evaluate an expression when it's written down. It evaluates it when something needs the result, and an expression nobody needs costs nothing. Terraform's providers are eager. Every provider the configuration mentions gets set up before planning starts, used or not. Nothing about the graph requires that. It's one call, made too early.

So Platformer ships providers that are lazy. `platformer.local/lazyprovider/aws` stands in front of `hashicorp/aws` and relays every message unchanged except one. When Terraform asks it to set up, it checks a setting of its own, `enabled`. A workspace that uses AWS sets it to true, and the real provider is set up on the spot, errors and all, exactly as before. A workspace that doesn't use AWS sets it to false, and the real provider is never set up at all: no login, no credentials, no failure. The setting is an ordinary provider argument, derived from the workspace's own declarations and evaluated inside the graph like everything else.

The proxy is a few hundred lines of Go, built from source by one script, once per version. That is a step, but not one between Terraform and the graph. It's the same kind of step as installing Terraform itself. Its address says so: `.local`, built on this machine. A shorter name would have pointed at the public registry, where anyone holding the matching name could publish something to answer an unbuilt checkout. Under `.local`, an unbuilt checkout simply fails, and asks for the build.

Now every cloud is part of every configuration, and every plan is one plan. The architecture never changes between workspaces; only which parts of it wake up. When Terraform opens the door it reserved, the proxy can retire, and each `enabled` becomes a `for_each`.

## Services Stay Generic

Platformer was designed around generic service modules. Compute, networking, storage and configuration management are services that other modules request things from, not piles of resources. Once clouds enter the picture, the temptation is to reorganize the repository by cloud: an `aws/` world and an `oci/` world, each with its own copy of compute, networking and storage. That would be the sparse world again, sorted alphabetically.

We won't do that. The service is the noun. Compute is a place for work to run, networking is the roads between places, storage is the silos. A service owns its interface: the shape of its state fragment, the requests other modules send it, the outputs it returns. That interface stays the same no matter where the service lands.

Inside each service, every cloud is an adapter in its own directory: `compute/aws/`, `compute/oci/`, `compute/localhost/`. Each adapter keeps the same promise. Give it the requests that belong to its cloud and the context it needs, and it returns results in the service's common shape. The generic layer routes each request to its cloud and merges what comes back, without ever naming a cloud resource. Each service calls all of its adapters; in a workspace that doesn't use a cloud, that cloud's adapter is still there, with its provider asleep. Adding Oracle to compute means adding `compute/oci/`. Nothing generic changes.

We chose directories over filename prefixes on purpose. A directory in Terraform is a module, and a module has inputs and outputs that Terraform itself enforces. That makes the adapter's promise a contract instead of a convention. Files that merely shared a prefix would share everything else too, every local and every variable, and the clouds would bleed into each other the first time someone was in a hurry.

A prototype of this runs today in a scratch harness: a generic compute service with two adapters, composed per workspace. With no clouds declared, their providers aren't even downloaded. With both declared, both adapters plan in a single graph, their results merge into one output, and a value from the core reaches the Oracle adapter as an ordinary reference.

## Uncoupling AWS

Today, AWS is not an adapter. AWS is the soil.

You can see it in the vocabulary. The compute module's class types are `ec2`, `eks` and `ecs`, product names rather than concepts, next to one honest concept, `localhost`. Class definitions carry `instance_type` and `ami_ssm_parameter` at the top level, as if every machine everywhere were an EC2 instance. The networking module checks for a twelve-digit AWS account number before it will allocate a single address. Every module inherits the AWS provider without asking, because the root configures it for everyone. From the outside, Platformer looks like an AWS-first framework.

That was never the intent. It was the result of what was available when Platformer was built.

So AWS becomes the first adapter, starting now, alongside Oracle rather than after it. Service by service, AWS resources move into `<service>/aws/`, and each service's generic interface is extracted from what the AWS implementation already does. The AWS code is the first draft of every contract. Oracle is the second reader, and a contract isn't really a contract until two implementations agree to it. We start where Oracle needs us first: networking and compute.

The vocabulary changes with it. A compute class says what it is, an instance or a cluster or a container, and where it lives:

```yaml
services:
  compute:
    docker:
      type: instance
      cloud: oci
      count: 2
      oci:
        shape: VM.Standard.E2.1.Micro
```

Common ideas live at the top. Details only one cloud understands live under that cloud's name, where they can't pretend to be universal.

Some modules will stay honest single-cloud products, and that's fine. arcbot is built on Bedrock and doesn't need to pretend otherwise. Its provider is AWS, and in a workspace without AWS it simply has nothing to wake up for.

For a while, users without AWS got by with placeholder credentials, harmless fakes that let the AWS provider set up without reaching AWS. They were scaffolding, and the lazy provider took them down: a workspace without AWS now leaves AWS asleep instead of fooling it.

## The Edge Nobody Else Can Draw

Here is what makes the effort worth it.

The Oracle machines Platformer builds will register with AWS Systems Manager as they boot, so the patch schedules, inventory and compose stacks that already exist can reach them. That registration needs an activation code issued by AWS.

In a sparse world, that's a handoff. One repository produces a code, someone copies it, another repository consumes it, and the two drift apart the first time the activation expires. In Platformer's graph, it's an edge. The Oracle machine's boot script references the AWS activation directly. One plan shows the activation issued in one cloud and the machine that will use it created in another. After that, patching and deployment find those machines by tag, through the management plane the industrial farm described, without either cloud's adapter knowing the other exists.

That's the fully connected view in one picture: two clouds, one graph, one plan, and every consequence visible before anything changes.

## Leaving a Cloud

Laziness introduces one new way to get hurt, so we design against it. A workspace could stop enabling a cloud while it still owns resources there. Those resources are still in the graph, and Terraform still needs their provider to read or remove them.

The lazy provider answers that honestly: it won't wake up just because a resource asks. Every resource still living in a disabled cloud fails the plan, by name, saying its provider is disabled in this workspace. Nothing is orphaned and nothing is destroyed by accident.

So the rule is simple: you can't leave a cloud by forgetting it. You leave a cloud the way you leave a house: empty it first, then hand back the keys.

## Terraforming

The world has pushed in one direction for a long time: toward sparsity. Smaller repositories, smaller teams, smaller blast radii, each owning a fragment and trusting the fragments to add up. Every man for himself, with a wiki page where the connections should be. Nobody planned it. It's what happens when everyone takes the nearest exit from a hard problem, and the nearest exit is always to make your own piece smaller.

Fine, then. We'll do it ourselves.

If connecting everything is the hard part, Platformer does the hard part, once, in the open, for everyone who uses it. The goal isn't to help people manage their fragments a little better. It's to do the connecting so thoroughly that there's nothing left to stitch together by hand: declare what you want and where it lives, and the graph does the rest. The best tool is the one that leaves its users no work to do.

The name was there all along. Terraforming means reshaping an entire world until it can support life: not a garden plot, not one valley, the whole planet at once. The industry took a tool with that name and used it to tend window boxes. Platformer takes the name literally. One graph for every cloud, every machine, and every edge between them. Managing the planet, with a terraformer.

## The Bet

This is a bet on a theory. The hypothesis is that a single, fully connected graph is a better way to run infrastructure than a federation of fragments, and that it holds across clouds, not just inside one. Clouds are where everyone else draws their hardest boundaries. If the hypothesis survives there, it survives anywhere.

We'll know it's failing if:

- adding a cloud to a service means editing the generic layer instead of adding a directory,
- the common interfaces collect so many cloud-specific escape hatches that "generic" stops meaning anything,
- the lazy provider grows past a few hundred lines, or starts making decisions that belong in the graph.

We'll know it's working when a second cloud is boring: when Oracle machines show up in the same plan as the AWS activations they depend on, get patched on the same schedule, and receive the same compose stacks. And when someone who has never had an AWS account can clone Platformer, declare Oracle, and plan.

Terraform's authors built a language that can describe everything at once. Almost nobody uses it that way. We intend to.

## Appendix: Where Things Stand

| Piece | Status |
|-------|--------|
| Unused providers block users without those clouds | Reproduced: a fresh clone without AWS credentials cannot plan |
| Placeholder credentials | Used for AWS as a stopgap, then removed; verified for Oracle and Google; impossible for Azure |
| Composition per workspace (a script before Terraform) | Built, then retired: it put a step between workspace switches and the graph |
| Lazy providers | Built: `lazyprovider/`, `platformer.local/lazyprovider/aws`, `platformer.local/lazyprovider/oci`, `platformer.local/lazyprovider/port`, each with `enabled`; real providers in `lazyprovider/upstreams.tf`; a clone with no cloud credentials plans |
| Port, a provider that logs in during setup | Built: behind the lazy proxy, set up only where `port_enabled = true` |
| Generic service with per-cloud adapter directories | Built: compute, with `compute/aws/` and `compute/oci/` |
| AWS extracted into adapters | Done with no plan changes for compute, networking, storage, secrets, access, domains, configuration-management and build |
| One vocabulary for instances | `type: instance` with `cloud: aws` or `cloud: oci`; EC2 settings live under `aws:` |
| Oracle adapters | Compute built; networking is referenced by ID, not yet managed |
| Oracle hosts owned by Platformer | docker-1 and docker-2 adopted (imported, unchanged); rebuilding them to register with Systems Manager at boot comes later |

## Appendix: First Steps

1. Give AWS its placeholder, so a clone without AWS credentials can plan today. (Done, then superseded.)
2. Make unused providers lazy instead of absent: one proxy, one argument, every cloud always in the graph. (Done.)
3. Split networking and compute into a generic layer and an AWS adapter, with no change to any existing plan. That's the proof the extraction is safe.
4. Add the Oracle adapters for networking and compute.
5. Bring the Oracle machines in: import their network, so the firewall rules the compose stack needs become code, then rebuild the machines through the Oracle compute adapter, registering with Systems Manager as they boot.

---

*The graph doesn't care which cloud a node lives in. It cares that every edge is real.*
