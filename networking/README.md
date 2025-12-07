# Networking

VPC and subnet management with deterministic CIDR allocation.

## Concept

Creates VPCs with predictable CIDR ranges using hash-based allocation. The same tenant identifier always produces the same VPC CIDR, enabling consistent network addressing across deployments.

Supports flexible subnet topologies with private, public, and custom tiers. Each tier automatically spans all configured availability zones.

## Key Features

- **Deterministic CIDR** - Hash tenant codes for predictable VPC ranges
- **Multi-AZ by Default** - Subnets automatically distributed across zones
- **Topology Flexibility** - Define private, public, intra, and custom tiers
- **High Availability NAT** - One NAT Gateway per AZ for redundant egress

## Allocation Methods

**Deterministic** - Hash-based allocation from a base CIDR range. Same input always produces same output.

**Explicit** - Manually specify VPC CIDR when deterministic allocation isn't suitable.

## Design Benefits

1. **Predictability** - Network topology remains consistent across recreations
2. **Multi-tenant Safe** - Hash function distributes ranges to avoid collisions
3. **Cost Control** - NAT Gateway count tied to AZ count (configurable)
4. **Extensible** - Custom subnet tiers without touching core logic
