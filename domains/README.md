# Domains

Route53 zone lookup and ACM wildcard certificate provisioning with DNS validation.

## Problem

EC2 instances serve web applications over plain HTTP. Corporate Zscaler proxies strip `Upgrade: websocket` headers on unencrypted connections, breaking WebSocket features (live metrics, terminal, hot reload). ACM cannot issue certificates for AWS default hostnames — a custom domain is required.

## Solution

This module looks up an existing Route53 hosted zone and provisions a wildcard ACM certificate (`*.{zone}`) with automated DNS validation. The certificate ARN is passed to the compute module via dependency inversion, where it's used for TLS termination on ALBs fronting HTTPS EC2 classes.

## Benefits

- **WebSocket Support** — HTTPS connections pass through Zscaler without header stripping
- **Zero-Touch Validation** — DNS validation records are created automatically in the hosted zone
- **Wildcard Coverage** — Single certificate covers all `{class}.{zone}` subdomains
- **Dependency Inversion** — Compute module receives certificate ARN as a variable, no tight coupling

## Configuration

```yaml
services:
  domains:
    zone: dev-platform.example.com
```

The hosted zone must already exist in the account. The module creates a wildcard certificate and waits for validation to complete before outputting the ARN.
