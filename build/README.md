# Build

Golden AMI builds for EC2 classes using Packer with SSM communicator. Extracted from compute to sit earlier in the dependency graph, enabling direct S3 access during builds.

## Concept

Building images is a separate concern from consuming them. EC2 classes with `build: true` get a golden AMI baked via Packer before instances are launched. The build module runs between storage (which creates the application-scripts bucket) and compute (which launches instances from the resulting AMIs).

This separation breaks the dependency cycle that previously existed when Packer builds needed resources (e.g., S3 buckets) from modules that depended on compute.

## Dependency Graph

```
config (class definitions) ──┐
storage (S3 buckets) ────────┼── build (Packer builds) ── compute (instance launches)
networks (VPC/subnets) ──────┘
```

## Key Features

- **Self-Contained AMI Resolution** - Resolves base AMIs internally via SSM parameters or AMI filters (same strategies as compute, no dependency on compute outputs)
- **S3 Access During Builds** - Packer IAM role includes S3 read access to the application-scripts bucket, so Ansible playbooks can download archives during golden AMI builds
- **Application Baking** - Merges class-level applications with standalone applications (wildcard/tags/compute targeting) into each build class
- **Content Hashing** - Recipe hash drives Packer template naming; changes to base AMI, volume size, or applications trigger a fresh build
- **Ansible Venv** - Creates a local Python virtualenv with Ansible and boto3 for playbook execution during builds
