# Legacy

Disposable EC2 instance with Atlantis pre-built via Packer.

## Concept

Packer builds AMI with Atlantis Docker image, then EC2 launches from that AMI with GitHub App auth configured. Atlantis starts automatically on port 80.

## Architecture

1. Packer builds AMI (~5-10 minutes)
2. EC2 instance launches from AMI
3. Atlantis runs as systemd service

Access via public IP (web UI) or SSM (SSH without keys).

## Secrets Required

- `dev/atlantis` - GitHub App key + webhook secret
- `prod/pltawporthook/github_token` - GitHub PAT for cloning infra-docker

Both must exist in AWS Secrets Manager before deployment.

**Note**: Packer failures now fail the entire deployment (no silent continuation).
