#!/bin/bash
set -euo pipefail

# SSM Hybrid Activation Container Entrypoint
# Runs inside the container to install SSM agent, register with AWS, and keep container alive
#
# Usage:
#   docker compose run agent /scripts/ssm-entrypoint.sh <activation-code> <activation-id> <region>

# Parse arguments
ACTIVATION_CODE="${1}"
ACTIVATION_ID="${2}"
REGION="${3:-us-east-2}"

# Validate arguments
if [ -z "$ACTIVATION_CODE" ] || [ -z "$ACTIVATION_ID" ]; then
  echo "Error: Missing required arguments"
  echo "Usage: $0 <activation-code> <activation-id> [region]"
  exit 1
fi

echo "=== SSM Hybrid Activation Setup ==="
echo "Activation ID: $ACTIVATION_ID"
echo "Region: $REGION"
echo ""

# Install minimal dependencies
echo "[1/3] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq curl ca-certificates > /dev/null 2>&1
echo "✓ Dependencies installed"
echo ""

# Download and install SSM agent package
echo "[2/3] Downloading and installing SSM agent..."
SSM_DEB_URL="https://amazon-ssm-${REGION}.s3.${REGION}.amazonaws.com/latest/debian_amd64/amazon-ssm-agent.deb"
echo "  Downloading from: $SSM_DEB_URL"
if ! curl -fsSL --connect-timeout 10 --max-time 120 "$SSM_DEB_URL" -o /tmp/amazon-ssm-agent.deb; then
  echo "✗ Failed to download SSM agent package"
  echo "  Check network connectivity and region: $REGION"
  exit 1
fi
echo "  Installing package..."
if ! dpkg -i /tmp/amazon-ssm-agent.deb > /dev/null 2>&1; then
  echo "✗ Failed to install SSM agent package"
  exit 1
fi
echo "✓ SSM agent installed"
echo ""

# Register with AWS Systems Manager using activation
echo "[3/3] Registering with AWS Systems Manager..."
if ! /usr/bin/amazon-ssm-agent -register -code "$ACTIVATION_CODE" -id "$ACTIVATION_ID" -region "$REGION" -y; then
  echo "✗ Registration failed"
  echo "  Check activation credentials and AWS connectivity"
  exit 1
fi
echo "✓ Registration complete"
echo ""

# Get instance ID from registration file
INSTANCE_ID=$(cat /var/lib/amazon/ssm/registration 2>/dev/null | grep -oP '"ManagedInstanceID"\s*:\s*"(mi-[a-z0-9]+)"' | grep -oP 'mi-[a-z0-9]+' || echo "")

echo "=== SSM Agent Starting ==="
if [ -n "$INSTANCE_ID" ]; then
  echo "Instance ID: $INSTANCE_ID"
else
  echo "Instance ID will be assigned after first heartbeat"
fi
echo ""
echo "Verify registration in AWS:"
echo "  aws ssm describe-instance-information --filters 'Key=ActivationIds,Values=$ACTIVATION_ID' --region $REGION"
echo ""
echo "Agent is running. Press Ctrl+C to stop."
echo ""

# Run SSM agent in foreground
# The agent runs as the main process, keeping the container alive
exec /usr/bin/amazon-ssm-agent
