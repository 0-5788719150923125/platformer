# Portal

Ephemeral Port.io integration for compute instance catalog visualization and self-service actions.

## Concept

Creates Port.io catalog entities for all EC2 instances and EKS clusters. Resources are transient—created at apply, destroyed at destroy.

Enables real-time dashboard of compute instances filtered by namespace, with self-service actions executed via AWS SSM.

## Features

**Catalog Visualization** - Dashboard of all compute instances with namespace filtering

**Self-Service Actions** - Execute commands on EC2 instances via Port UI, powered by SSM

**Live Log Streaming** - Real-time command output streamed to Port

**Local Execution** - Port agent runs locally via Docker Compose (no public endpoints)

## Architecture

User clicks action in Port UI → Port sends invocation → Local agent (Docker) receives → Action handler executes via SSM → Output streams back to Port

All services run locally. No public endpoints required. Services automatically start at apply, stop at destroy.

## Namespace Isolation

Entities identified as `{instance-key}-{namespace}`. Filter by namespace in Port UI to view only your deployment's instances.
