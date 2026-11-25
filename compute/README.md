# Compute

Unified compute provisioning with type-based routing. Single configuration interface for EC2, EKS, and future compute platforms.

## Concept

Rather than separate modules for each compute type, this module provides a unified `classes` configuration. The `type` field determines which implementation to use - EC2 instances, EKS clusters, Lambda functions, ECS tasks, etc.

## Current Support

**EC2** - Multi-tenant instance provisioning with class-based configuration. Instances automatically register with SSM via DHMC (no IAM instance profiles). Supports application installation via SSM documents, Ansible playbooks, or user-data scripts.

**EKS** - Kubernetes clusters with managed node groups. Automatic kubeconfig management with context names matching class names. Supports Helm chart installations.

**Generic instances (`type: instance`)** - A class names the cloud it lives in (`cloud: oci`) and carries that cloud's settings under its name (`oci:`). Instances expand across tenants like EC2 (`<tenant>-<class>-<idx>`). `adopt` lists existing instance IDs to import instead of create; the plan shows them as "will be imported".

## Cloud Adapters

This directory is the generic layer; each cloud's implementation is an adapter in a subdirectory with its own tests:

- `aws/` - AWS, the reference implementation (`ec2`, `eks`, `ecs`). Always on, called from `main.tf`. Until its settings move under an `aws:` key it takes exactly the same inputs as compute (`aws/variables.tf` links to `variables.tf`).
- `oci/` - Oracle Cloud (`type: instance`, `cloud: oci`). Wired in only in workspaces that set `oci_profile`, by `scripts/providers.sh`, which writes `adapter_oci.tf` and `adapters_override.tf` here. Instances can't be destroyed by a plan (`prevent_destroy`), and networking is referenced by subnet OCID, never managed.
- `localhost.tf` - runs applications on the machine running Terraform.

`adapters.tf` routes generic instance classes to their cloud and merges the results (`adapter_instances`, `adoptions`). The plan fails if a class uses a cloud whose adapter isn't wired in, or if a class with `adopt` isn't entitled to exactly one tenant. Tests in `compute/tests` assume no optional providers are wired in. See `next/fully-connected.md` for the design.

## Tenant Expansion

EC2 classes automatically expand across tenants. A single class definition with `count: 2` and `tenants: ["a", "b"]` creates 4 instances: `a-class-0`, `a-class-1`, `b-class-0`, `b-class-1`.

Tenant overrides allow per-tenant instance type selection and class filtering.

## Design Benefits

1. **Unified Interface** - One configuration pattern for all compute
2. **Type Safety** - Configuration validated per compute type
3. **Extensibility** - Adding new compute types doesn't break existing configs
4. **Namespace Isolation** - All resources scoped to deployment namespace
