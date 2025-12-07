#!/bin/bash
set -euo pipefail

# Atlantis startup wrapper script for GitHub App authentication
# This script is called by systemd and handles all the complexity of starting the Docker container
# Arguments:
#   $1 - Atlantis port
#   $2 - Region
#   $3 - Repo allowlist

ATLANTIS_PORT="${1}"
REGION="${2}"
REPO_ALLOWLIST="${3}"

# Get local IP from EC2 metadata
LOCAL_IP=$(ec2-metadata --local-ipv4 | cut -d " " -f 2)

# Read secrets from environment file safely (using grep/cut to avoid sourcing)
if [ -f /etc/atlantis/secrets.env ]; then
  ATLANTIS_GH_WEBHOOK_SECRET=$(grep '^ATLANTIS_GH_WEBHOOK_SECRET=' /etc/atlantis/secrets.env | cut -d= -f2-)
  ATLANTIS_WEB_USERNAME=$(grep '^ATLANTIS_WEB_USERNAME=' /etc/atlantis/secrets.env | cut -d= -f2-)
  ATLANTIS_WEB_PASSWORD=$(grep '^ATLANTIS_WEB_PASSWORD=' /etc/atlantis/secrets.env | cut -d= -f2-)
else
  echo "ERROR: Secrets file not found at /etc/atlantis/secrets.env"
  exit 1
fi

# Start Atlantis container with GitHub App authentication
# Docker handles special characters in -e flags properly (no shell interpretation)
exec /usr/bin/docker run --rm \
  --name atlantis \
  --health-cmd "wget --no-verbose --tries=1 --spider http://localhost:${ATLANTIS_PORT}/healthz || exit 1" \
  --health-interval 30s \
  --health-timeout 3s \
  --health-retries 3 \
  -p "${ATLANTIS_PORT}:${ATLANTIS_PORT}" \
  -v /opt/atlantis/data:/atlantis-data \
  -v /etc/atlantis/github-app:/var/github-app:ro \
  -v /etc/atlantis/repos.yaml:/etc/atlantis/repos.yaml:ro \
  -e "ATLANTIS_ATLANTIS_URL=http://${LOCAL_IP}:${ATLANTIS_PORT}" \
  -e "ATLANTIS_REPO_ALLOWLIST=${REPO_ALLOWLIST}" \
  -e "ATLANTIS_DATA_DIR=/atlantis-data" \
  -e "ATLANTIS_PORT=${ATLANTIS_PORT}" \
  -e "ATLANTIS_LOG_LEVEL=info" \
  -e "AWS_REGION=${REGION}" \
  -e "AWS_DEFAULT_REGION=${REGION}" \
  -e "ATLANTIS_GH_APP_ID=1061798" \
  -e "ATLANTIS_GH_APP_INSTALLATION_ID=57650555" \
  -e "ATLANTIS_GH_APP_KEY_FILE=/var/github-app/key.pem" \
  -e "ATLANTIS_GH_APP_SLUG=pltdeployer" \
  -e "ATLANTIS_WRITE_GIT_CREDS=true" \
  -e "ATLANTIS_GH_WEBHOOK_SECRET=${ATLANTIS_GH_WEBHOOK_SECRET}" \
  -e "ATLANTIS_REPO_CONFIG=/etc/atlantis/repos.yaml" \
  -e "ATLANTIS_GH_TEAM_ALLOWLIST=platform:state_rm,platform:import,platform:version,platform:plan,platform:apply,platform:unlock,sre:unlock,sre:import,sre:version,sre:plan,sre:apply" \
  -e "ATLANTIS_WEB_BASIC_AUTH=true" \
  -e "ATLANTIS_WEB_USERNAME=${ATLANTIS_WEB_USERNAME}" \
  -e "ATLANTIS_WEB_PASSWORD=${ATLANTIS_WEB_PASSWORD}" \
  -e "ATLANTIS_DEFAULT_TF_VERSION=v1.11.4" \
  -e "ATLANTIS_CHECKOUT_STRATEGY=merge" \
  -e "TF_INPUT=false" \
  -e "TF_IN_AUTOMATION=true" \
  local-atlantis:latest \
  server
