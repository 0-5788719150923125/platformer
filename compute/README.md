# Compute

Unified compute provisioning with type-based routing. Single configuration interface for EC2, EKS, and future compute platforms.

## Concept

Rather than separate modules for each compute type, this module provides a unified `classes` configuration. The `type` field determines which implementation to use—EC2 instances, EKS clusters, Lambda functions, ECS tasks, etc.

## Current Support

**EC2** - Multi-tenant instance provisioning with class-based configuration. Instances automatically register with SSM via DHMC (no IAM instance profiles). Supports application installation via SSM documents, Ansible playbooks, or user-data scripts.

**EKS** - Kubernetes clusters with managed node groups. Automatic kubeconfig management with context names matching class names. Supports Helm chart installations.

## Tenant Expansion

EC2 classes automatically expand across tenants. A single class definition with `count: 2` and `tenants: ["a", "b"]` creates 4 instances: `a-class-0`, `a-class-1`, `b-class-0`, `b-class-1`.

Tenant overrides allow per-tenant instance type selection and class filtering.

## Design Benefits

1. **Unified Interface** - One configuration pattern for all compute
2. **Type Safety** - Configuration validated per compute type
3. **Extensibility** - Adding new compute types doesn't break existing configs
4. **Namespace Isolation** - All resources scoped to deployment namespace
