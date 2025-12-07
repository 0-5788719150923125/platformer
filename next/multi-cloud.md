# Multi-Cloud: The Industrial Farm

## Prologue: Two Farms

There are two farms in this valley.

The first farm has been here for generations. Every animal has a name. Bessie the cow stands in stall three, where she has always stood. When Bessie gets sick, the farmer calls the veterinarian, who knows Bessie personally—her medical history, her temperament, her particular needs. The farmer keeps a ledger: Bessie's milk production, her feeding schedule, her lineage. When Bessie dies, there is grief. The stall sits empty for a time. Eventually, a new cow arrives, and the farmer begins a new page in the ledger.

This farm has forty cows. The farmer knows each one. The operation works.

The second farm looks different. There are no names on the stalls—only numbers. The cows are organized by function: dairy production in barn A, breeding stock in barn B. When a cow gets sick, the protocol is the same regardless of which cow: isolate, treat, return to herd or cull. The farmer doesn't track individual animals; the farmer tracks *herds*. Milk production is measured by barn, not by stall. New cows arrive and slot into available positions. The system continues.

This farm has four thousand cows. The farmer manages them through systems, not relationships.

Neither farm is wrong. But only one of them scales.

## Part I: The Naming of Things

In the beginning, there was one server. It needed a name—something to call it, something to put in the DNS record, something to write on the monitoring dashboard. The engineer named it after its purpose, or its location, or perhaps a character from mythology. The server had an identity.

Then there were two servers. They got names too. Similar names, because they did similar things, but distinct names because they were distinct machines. The engineer could tell them apart. The engineer *needed* to tell them apart, because each one was configured slightly differently, ran slightly different versions, had slightly different quirks.

Then there were ten servers. Then a hundred. Then servers across multiple datacenters, multiple clouds, multiple tenants. And still, each one got a name. Each one got a file. Each one got a stall in the barn, a page in the ledger, a veterinarian who knew its history.

This is how organizations build pets.

The pattern is seductive because it *works*—at small scale. When you have forty servers, you can know them all. You can remember that `storelua01` runs on older hardware and needs the compatibility flag. You can recall that `tclpa03` was rebuilt last month after the disk failure. You can maintain the ledger.

But the ledger doesn't scale. When you have seven hundred servers, each with its own configuration file, each with its own hardcoded IP address, each with its own DNS record, each with its own patch group—you no longer have infrastructure. You have a museum of individual artifacts, each requiring individual care.

The evidence is everywhere, for those who look:

- Directories named after servers, multiplied by hundreds
- IP addresses manually allocated and tracked in IPAM software
- Patch management configurations that must be duplicated per server, per tenant, per environment
- Security groups with tenant-specific rules, copied and modified rather than composed
- State files fragmented across hundreds of locations, one per snowflake

The engineers who built these systems weren't wrong. They were solving immediate problems with available tools. They named their servers because servers needed names. They created per-server configurations because each server was, genuinely, a little bit different.

But somewhere along the way, the farm grew beyond what individual relationships could manage. And instead of changing the model—instead of moving from named cows to numbered herds—the organization simply... kept naming. Kept creating files. Kept maintaining the ledger, even as the ledger grew beyond any human's ability to comprehend.

The cows have names. This is why we cannot scale.

## Part II: The Vision of the Industrial Farm

Imagine a different model.

The industrial farm doesn't name its cattle. It *classifies* them. Dairy cows are dairy cows—they share characteristics, they receive similar care, they produce similar outputs. The farmer doesn't track individual animals; the farmer tracks *populations*. How many dairy cows? What's the aggregate milk production? What's the health status of the herd?

This isn't cold or impersonal. It's *appropriate to scale*. When you manage four thousand cows, you cannot provide individual veterinary care to each one. You must create systems: health monitoring that flags anomalies, feeding protocols that apply to categories, breeding programs that operate on populations. The individual cow still matters—a sick cow still gets treated—but the *system* that identifies and treats sick cows operates at herd level, not at individual level.

Platformer is the blueprint for the industrial farm.

The vision is expansive: infrastructure that spans every cloud—AWS, Azure, GCP, on-premises datacenters, private clouds, edge deployments—managed through a single operational model. Not by knowing every server individually, but by knowing what *kinds* of servers exist, what they need, and how to ensure they receive it.

This requires four capabilities that the current model lacks:

1. **Automated Migrations**: The ability to move cattle between pastures
2. **Universal Device Management**: The ability to care for cattle regardless of which barn they occupy
3. **Unified Networking**: The ability to connect pastures, including the roads between them
4. **Storage as Cattle**: The ability to treat data infrastructure the same way we treat compute

Each of these deserves examination.

## Part III: Moving the Herd (Automated Migrations)

Cattle move. This is fundamental to farming at scale.

Seasonal migrations move herds to fresh pastures. Market conditions shift cattle between facilities. Drought or disaster forces emergency relocations. The industrial farm doesn't ask "how do we move Bessie?" It asks "how do we move herds?"

In infrastructure terms: tenants move. They migrate from on-premises to cloud. They shift between cloud providers. They consolidate datacenters. They respond to regulatory requirements, cost pressures, disaster recovery needs. The organization that built its infrastructure around named servers cannot migrate efficiently, because migration requires touching every name, every file, every configuration.

**The current state**: Migrations are manual, multi-week processes. Engineers enumerate resources by hand. State files are surgically manipulated. Import commands are run one at a time, hundreds of times. Configuration drift is discovered only when the migration fails. Rollback is theoretical.

**What industrial farming requires**: Migrations as a systematic capability.

```yaml
services:
  migration:
    type: lift-and-shift
    source:
      provider: on-premises
      discovery: automatic
    target:
      provider: aws
      account_pattern: "*-prod"
    strategy:
      - discover_resources      # Scan source, catalog everything
      - generate_import_blocks  # Create Terraform import configuration
      - provision_target        # Build destination infrastructure
      - replicate_data          # Move stateful content
      - validate_parity         # Confirm source and target match
      - cutover                 # Switch traffic
      - decommission_source     # Clean up origin
```

The individual server doesn't matter. What matters is the *herd*: all the servers of a particular type, moving together, validated together, cut over together. The migration is defined once and executed systematically. The farmer doesn't lead each cow individually across the valley; the farmer opens the gate and the herd moves.

This capability is essential because tenant mobility is part of the business model. Healthcare organizations consolidate. Practices merge. Regulatory requirements shift workloads between jurisdictions. An organization that cannot migrate efficiently is an organization that cannot serve its tenants' evolving needs.

## Part IV: The Veterinarian Who Visits Every Barn (Universal Device Management)

On the small farm, the veterinarian knows each animal. On the industrial farm, the veterinarian knows *protocols*.

The protocol doesn't care which barn the cow occupies. Vaccination schedules apply to all dairy cows. Health monitoring applies to all cattle. Treatment protocols apply based on condition, not on which stall the animal happens to occupy.

In infrastructure terms: patch management, configuration management, compliance enforcement—these must operate regardless of where the server lives. A server in AWS and a server in Azure and a server in an on-premises datacenter all need security patches. They all need configuration baselines. They all need compliance validation.

**The current state**: Patch management is fragmented by environment, by tenant, by server type, by cloud provider. Some environments have patching disabled entirely. Others have patch groups proliferated to the point of meaninglessness—dozens of separate maintenance windows, each targeting a handful of servers, each requiring individual configuration. The veterinarian visits some barns but not others, follows different protocols in each, and maintains no unified health record.

**What industrial farming requires**: A single system that manages all cattle, regardless of location.

AWS Systems Manager provides this capability through hybrid activations. A server anywhere—in AWS, in Azure, in a private datacenter, on a developer's laptop—can register with SSM and receive the same management capabilities: Run Command for remote execution, State Manager for configuration enforcement, Patch Manager for security updates, Session Manager for access.

```yaml
services:
  configuration-management:
    # These settings apply to ALL enrolled devices
    patch_schedule: "cron(0 4 ? * SUN *)"  # Weekly, 4 AM Sunday
    compliance_baseline: "critical-security"

    # Devices enroll automatically based on infrastructure type
    enrollment:
      aws_instances: automatic       # EC2 instances via instance profile
      hybrid_activations:            # Non-AWS via activation codes
        azure_vms:
          registration_limit: 100
        on_premises:
          registration_limit: 500
        developer_workstations:
          registration_limit: 50
```

The veterinarian visits every barn—not because the veterinarian knows each barn individually, but because the veterinarian follows a protocol that works everywhere. Devices enroll themselves. Patch schedules apply universally. Compliance is validated continuously. The farmer doesn't track which cows have been vaccinated; the system tracks which cows have been vaccinated, and flags those that haven't.

This is particularly critical for multi-cloud. When infrastructure spans AWS and Azure and on-premises, fragmented management is not an option. Either you have one system that manages everything, or you have N systems that each manage a fragment, with gaps between them where servers fall through and remain unpatched, unmanaged, non-compliant.

The industrial farm cannot afford gaps. Neither can healthcare infrastructure.

## Part V: The Roads Between Pastures (Unified Networking)

Pastures must be connected. Cattle move between them. Farmers travel between them. Feed and equipment and veterinary supplies flow between them.

But not all pastures should be connected to all other pastures. The dairy operation doesn't need direct access to the breeding facility. The quarantine area must be isolated. The roads exist, but they're controlled—gates and fences determine which traffic flows where.

In infrastructure terms: networking is the circulatory system of multi-cloud. And in healthcare, the most critical component is often the most overlooked: **VPNs**.

Healthcare organizations run on VPNs. Hospitals connect to imaging centers. Practices connect to cloud services. Radiologists connect from home. Every tenant deployment involves VPN configuration—site-to-site tunnels, client VPNs, split tunneling rules, certificate management. The organization that cannot manage VPNs efficiently cannot serve healthcare tenants.

**The current state**: VPN configurations are scattered across tenant directories. Each tenant has bespoke tunnel configurations. CIDR blocks are manually allocated from spreadsheets. Security groups duplicate rules across tenants with minor variations. Adding a new tenant means copying configuration from a similar tenant and hoping the differences are understood.

**What industrial farming requires**: Networking as a systematic capability, including VPN orchestration.

```yaml
services:
  network:
    # Deterministic CIDR allocation eliminates manual IP management
    allocation_method: deterministic  # Hash tenant code to CIDR block
    base_cidr: "10.0.0.0/8"

    # Topology defined once, applied everywhere
    subnet_topology:
      private:
        cidr_bits: 8
        nat_gateway: true
      public:
        cidr_bits: 10
        internet_gateway: true
      vpn:
        cidr_bits: 12
        purpose: tenant_connectivity

    # VPN as a service, not as bespoke configuration
    vpn_connections:
      tenant_sites:
        type: site-to-site
        routing: bgp_dynamic          # No manual route management
        redundancy: multi_tunnel
      cloud_to_cloud:
        type: transit
        purpose: migration_corridor   # Temporary connections during migrations
        auto_teardown: true
```

The roads between pastures are standardized. Every pasture gets the same topology. New pastures are connected automatically. Tenant VPNs follow a template. Cloud-to-cloud connectivity—essential during migrations—is provisioned on demand and removed when no longer needed.

The industrial farm doesn't survey and pave a new road for each pasture. It follows a road-building protocol that produces consistent, maintainable infrastructure.

## Part VI: The Grain Silos (Storage as Cattle)

The small farm has a barn. The barn has a loft. The loft stores hay. The farmer knows exactly where the hay is, because there's only one place it could be.

The industrial farm has grain silos—dozens of them, distributed across the property. The farmer doesn't track which silo holds which grain. The farmer tracks *inventory*: how much wheat, how much corn, how much feed. When a silo empties, it's refilled. When a silo fails, its contents are redistributed. The individual silo doesn't matter; the aggregate storage capacity matters.

In infrastructure terms: storage must be cattle, not pets.

**The current state**: Storage provisioning follows the same pet pattern as compute. Each tenant has bespoke S3 configurations. Bucket policies are generated once and committed as code, then manually modified as requirements evolve. Lambda functions provision buckets outside of Terraform state, creating resources that exist but aren't managed. The grain is in the silos, but no one knows exactly where, and the inventory system disagrees with reality.

**What industrial farming requires**: Storage declared through interfaces, provisioned through patterns.

```yaml
services:
  configuration-management:
    # Service declares storage need
    s3_output_bucket_enabled: true

  # Storage module auto-enables, creates bucket with standard policies
  # No per-tenant configuration
  # No generated code
  # No Lambda provisioning layer
  # No drift between template and reality
```

The storage module operates on the dependency inversion principle: services declare what they need, the storage system provides it. The declaration is simple—"I need a bucket." The implementation is standardized—encryption, access logging, lifecycle policies, all applied consistently. The bucket exists because the service needs it; the bucket disappears when the service no longer needs it.

This is the grain silo model. The farmer doesn't name silos. The farmer declares capacity requirements, and the infrastructure provides storage. Adding capacity means updating a number, not creating files.

## Part VII: The Integration

These capabilities are not independent. They form a system.

**Migrations require networking**: Moving a herd between pastures requires roads. Cloud-to-cloud migrations require connectivity between clouds—VPN tunnels that carry traffic during cutover, that allow validation of the new environment before committing, that enable rollback if something fails.

**Migrations require device management**: Moved cattle must be enrolled in the new farm's systems. When servers migrate from on-premises to AWS, they must register with Systems Manager, join patch groups, receive configuration baselines. The migration is not complete when the server boots; it's complete when the server is *managed*.

**Migrations require storage orchestration**: Data moves with workloads. Database snapshots, object storage, persistent volumes—all must be replicated to the destination before cutover. The storage system must provision destination resources automatically, not through manual bucket creation.

**Device management requires networking**: The veterinarian must be able to reach every barn. SSM agents must communicate with AWS endpoints. Hybrid activations require outbound HTTPS connectivity. Patch downloads require repository access. Networking enables management.

**Storage requires device management**: Backup agents run on servers. Log shipping requires connectivity. Data lifecycle policies require compliance validation. Storage and compute are connected through the management plane.

The industrial farm is a *system*, not a collection of independent operations. The roads connect to the barns connect to the silos connect to the veterinary office. Information flows. Cattle move. Grain is distributed. Health is monitored. The farmer manages the system, not the individual components.

## Part VIII: Why the Ledger Must Close

The small farm's ledger is beautiful. Pages filled with careful handwriting. Bessie's complete history: when she was born, when she calved, when she was sick, when she recovered. The farmer can trace any cow's lineage, recall any cow's story.

But the ledger is also a prison.

Every new cow requires a new page. Every event requires an entry. The farmer spends more time writing in the ledger than working with the cattle. And when the farmer retires, the knowledge in their head—the context that makes the ledger meaningful—retires with them. The next farmer inherits pages of names and dates without understanding what they mean.

The infrastructure ledger looks like this:

- Seven hundred server configurations, each in its own file
- IP addresses tracked in spreadsheets that drift from reality
- Patch groups multiplied until they lose meaning
- Security rules duplicated with slight variations, no one remembering why
- State files scattered across hundreds of locations

Engineers maintain this ledger because it's what they inherited. They add new pages because that's how pages have always been added. They don't question the model because the model is so pervasive that it feels inevitable.

But it's not inevitable. It's a choice.

The industrial farm chose differently. Instead of a ledger of individuals, it maintains a registry of populations. Instead of tracking each cow, it tracks herds. Instead of configuration files per server, it maintains patterns that produce servers. The individual is still there—you can query the system and find any specific cow—but the individual is an *output* of the system, not an *input* to it.

This is the fundamental shift that Platformer represents.

## Part IX: The Multi-Cloud Farm

The vision, fully stated:

**Platformer manages infrastructure across every cloud—AWS, Azure, GCP, on-premises datacenters, private clouds, edge deployments—through a unified operational model based on cattle principles.**

This means:

1. **No named servers**. Servers are instances of patterns. A "Rocky Linux compute node" is defined once; the system produces as many as needed. The server's identity comes from its function, not from a name in a file.

2. **No manual CIDR management**. Network topology is deterministic. Given a tenant code and a region, the system calculates the appropriate CIDR blocks. No spreadsheets. No manual allocation. No "check with the network team."

3. **No per-tenant VPN configuration**. VPN connectivity follows patterns. Tenant site-to-site VPNs are declared through interfaces; the system provisions tunnels. Cloud-to-cloud migration corridors are created on demand and removed when complete.

4. **No fragmented patch management**. Every server—regardless of cloud, regardless of tenant, regardless of environment—enrolls in a unified management plane. Patch schedules apply universally. Compliance is validated continuously. No server falls through the cracks.

5. **No storage pets**. Services declare storage needs. The storage system provides buckets, databases, caches—with consistent security, consistent policies, consistent lifecycle management. No generated code. No Lambda provisioning layers. No drift.

6. **No migration projects**. Migrations are operational capabilities. Move a tenant from on-premises to AWS: declare the migration, execute the workflow, validate the result. The system handles discovery, import, replication, cutover. No spreadsheets. No months of manual coordination.

This is not a distant vision. The components exist:

- The configuration-management module already supports hybrid activations
- The networking module already implements deterministic CIDR allocation
- The storage module already operates on dependency inversion
- The state fragment system already enables pattern-based targeting

What remains is integration—connecting these capabilities into a unified multi-cloud operational model—and adoption.

## Part X: The Farmhands

The small farm had one farmer. The farmer did everything: fed the cattle, repaired the fences, maintained the ledger, called the veterinarian, drove the tractor, stored the grain. The farmer understood the whole operation because the farmer *was* the whole operation.

As the farm grew, specialization emerged. One person fed the cattle. Another maintained fences. A third drove tractors. A fourth managed grain storage. Each farmhand became expert in their domain—deeply knowledgeable about their specific responsibilities, intimately familiar with their particular corner of the operation.

This specialization was necessary. No single person could master four thousand cows, two hundred miles of fencing, a fleet of machinery, and industrial grain storage. The work exceeded individual capacity. Division of labor was the only path forward.

But specialization creates silos. The cattle specialist knows everything about feeding schedules but nothing about fence maintenance. The tractor operator knows the fields intimately but has never entered the grain silos. Each farmhand sees the farm through their particular window—and that window, however clear, shows only a fragment of the whole.

From ground level, these fragments look like the entire world. The cattle specialist's universe *is* the cattle. The fence worker's universe *is* the fences. Ask them about the farm, and they describe their fragment. Ask them about operations beyond their fragment, and they shrug: "That's not my area."

But climb into a crop duster. Rise two thousand feet. Look down.

From altitude, the fragments disappear. There are no specialists visible from here—only patterns. The cattle form herds that move across pastures. The fences trace boundaries that separate functions. The tractors follow routes that connect operations. The silos cluster near the processing facilities. The whole farm is visible, and it looks... *systematic*. The individual expertise that seemed so critical from ground level is invisible from above. What matters is how the pieces connect, how the flows move, how the system operates as a whole.

This is the perspective that specialization obscures.

---

The organization has hundreds of employees. Each has become expert in their fragment: this tenant's configuration, that region's networking, these servers' patch management, those applications' deployment patterns. The expertise is real. The knowledge is genuine. Years of experience have produced farmhands who know their domains deeply.

But the domains are artificial. The tenant boundary is artificial—infrastructure is infrastructure, regardless of which tenant it serves. The regional boundary is artificial—a VPC in us-east-2 operates the same way as a VPC in eu-west-1. The server boundary is artificial—`storelua01` is just another Linux host, not a unique entity requiring unique expertise.

The specialization that felt necessary—that *was* necessary, given the tools available—has become a prison. Farmhands who know their fragment cannot see the whole. They cannot recognize that their fragment is identical to dozens of other fragments maintained by dozens of other specialists. They cannot perceive that the work they do manually, repeatedly, expertly, is the *same work* being done manually, repeatedly, expertly by colleagues they've never met.

And when someone proposes automation—when someone suggests that the crop duster could fertilize all fields simultaneously instead of farmhands walking each row individually—the specialists resist.

The resistance is understandable. "You don't understand my field," they say. "My cattle have specific needs. My fences require particular attention. My tractors need specialized maintenance." And they're not wrong—viewed from ground level, through their window, the specificity is real. The expertise is real. The differences they perceive are real.

But from two thousand feet, the fields are fields. The cattle are cattle. The fences are fences. The apparent uniqueness dissolves into pattern. The specialized knowledge that seemed essential reveals itself as *knowledge of a pattern applied to a specific instance*—and once you see the pattern, you don't need knowledge of every instance. You need knowledge of the pattern.

---

This is not a critique of the farmhands. They did their jobs. They maintained their fragments. They kept the operation running through years of growth, through acquisitions and expansions, through crises that demanded expert response. The farm exists because of their work.

But the farm has outgrown the model. Four thousand cows cannot be fed by farmhands who each know forty cows. Two hundred miles of fence cannot be maintained by workers who each know two miles. The fragments have multiplied beyond human coordination capacity. The specialists who once were essential have become bottlenecks—not through any fault of their own, but because specialization doesn't scale.

The crop duster doesn't replace the farmhands. It *transforms* what farmhands do.

The farmhand who walked rows spreading fertilizer by hand? They now operate the crop duster, covering in an hour what used to take a week. The expertise isn't gone—it's elevated. Instead of knowing one field intimately, they know *fields*: soil composition, weather patterns, fertilizer chemistry, application timing. The domain expanded from a fragment to a system.

The cattle specialist who knew forty cows by name? They now manage herd health through monitoring systems, analyzing population trends, designing protocols that apply to thousands. The expertise isn't gone—it's elevated. Instead of knowing Bessie's history, they know *cattle*: breed characteristics, disease patterns, nutrition requirements, lifecycle management.

The role transforms from *executor* to *orchestrator*. The work shifts from *doing* to *designing systems that do*. The farmhand becomes an architect of farming operations, not a performer of farming tasks.

---

This transformation is uncomfortable. It requires admitting that the expertise which felt essential—the knowledge of forty cows, two miles of fence, one tenant's configuration—is not essential. It requires accepting that years of specialized knowledge, while valuable, describe patterns that can be automated. It requires acknowledging that the fragment which seemed like the whole world is, from altitude, indistinguishable from hundreds of other fragments.

Some farmhands will resist. "You're replacing us," they'll say. And in a sense, they're right—the *role* is being replaced. Walking rows is replaced by flying fields. Knowing individual cows is replaced by managing herd systems. Maintaining individual server configurations is replaced by designing patterns that produce configurations.

But the *people* aren't replaced. They're needed—more than ever. The crop duster needs a pilot. The herd management system needs a designer. The configuration patterns need architects. The expertise that farmhands developed over years—understanding cattle, understanding fields, understanding fences—is exactly the expertise needed to design systems that manage cattle, fields, and fences at scale.

The question is whether they can make the transition. Whether they can release the grip on their fragment and rise to see the whole. Whether they can accept that their window, however clear, showed only a piece of a pattern that extends far beyond their view.

The farm needs everyone on the same page. Not everyone doing the same thing—the cattle architect and the fence engineer and the grain systems designer will have different responsibilities. But everyone seeing the same farm. Everyone understanding how their work connects to the whole. Everyone contributing to the orchestration system, not just executing fragments of it.

From ground level, each fragment feels unique. From two thousand feet, the pattern is clear.

We need people who can see from two thousand feet.

## Epilogue: The Naming of Things, Revisited

The small farm named its cows because naming was natural. Bessie was Bessie. The relationship was real.

The industrial farm numbers its cattle not because it cares less, but because it cares *differently*. It cares about herd health, not individual biography. It cares about aggregate productivity, not individual history. It cares about sustainable operations at scale, not heroic individual effort.

Both models produce milk. Both models raise cattle. But only one model can feed a nation.

The infrastructure we've built over the years named its servers because naming was natural. `storelua01` was `storelua01`. The configuration file was real, the IP address was real, the patch group was real.

But we are not a small farm anymore. We manage infrastructure across 127 AWS accounts. We serve healthcare organizations across the globe. We face integration with an organization spanning 160 countries. The naming model that worked for forty servers does not work for four thousand servers.

The ledger must close. The names must give way to patterns. The individual configuration files must give way to templates that produce configurations. The manual coordination must give way to systems that coordinate automatically.

This is not a loss. The servers don't care what they're called. The patients whose images flow through our infrastructure don't care how the infrastructure is organized. What they care about is reliability—that the system works, that security patches are applied, that migrations succeed, that the infrastructure serves its purpose.

The industrial farm serves its purpose. The cattle are healthy. The milk flows. The grain is stored. The roads connect the pastures.

The farmer sleeps at night, because the systems are working.

## Appendix: Implementation Status

| Capability | Status | Notes |
|------------|--------|-------|
| **Hybrid Activations** | POC Complete | SSM agent registration working for non-AWS hosts |
| **Deterministic Networking** | POC Complete | Hash-based CIDR allocation, automatic VPC targeting |
| **Storage Dependency Inversion** | Implemented | Services declare needs, storage auto-provisions |
| **VPN Orchestration** | Not Started | Architecture documented, implementation pending |
| **Migration Automation** | Not Started | Architecture documented, Q2 2025 priority |
| **Multi-Cloud Provider Support** | Partial | AWS primary, Azure/GCP patterns defined |

## Appendix: State Fragment Examples

**Unified compute with automatic networking and management enrollment:**
```yaml
services:
  compute:
    tenants: [tenant_a, tenant_b]
    classes:
      imaging-server:
        type: ec2
        instance_type: m6i.xlarge
        count: 3
        # No subnet configuration - automatically uses private subnet
        # No patch group - automatically inherits from class
        # No IP allocation - automatically assigned

  network:
    allocation_method: deterministic
    enable_nat_gateway: true
    # No CIDR specification - calculated from account ID

  configuration-management:
    patch_schedule: "cron(0 4 ? * SUN *)"
    # Applies to all compute instances automatically
    # Including hybrid-activated non-AWS hosts
```

**Migration corridor for cloud-to-cloud movement:**
```yaml
services:
  migration:
    source:
      provider: on-premises
      datacenter: nas6
    target:
      provider: aws
      account_pattern: "*-prod"

  network:
    vpn_connections:
      migration_corridor:
        type: site-to-site
        source_cidr: "10.0.0.0/16"
        target_vpc: automatic
        auto_teardown_after_migration: true
```

---

*The cows don't need names. They need care. And care, at scale, comes from systems—not from ledgers.*
