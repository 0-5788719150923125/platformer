# Resolver

Dependency resolution engine. Determines which modules need to be enabled based on service configurations.

## Purpose

Analyzes service configurations and produces enable flags for each module. Handles both explicit (directly configured) and implicit (needed by other services) dependencies.

When configuration-management is enabled, the resolver automatically enables compute (instances to manage) and storage (S3 for logs). When observability is enabled, it auto-enables compute (EKS cluster), storage (Loki buckets), applications (Helm charts), and configuration-management (Alloy agents).

## Design

Always called after the config module. Provides enable flags that control conditional module instantiation via `count` parameters. This allows the root configuration to remain static while services dynamically enable/disable based on state fragments.
