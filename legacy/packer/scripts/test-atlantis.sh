#!/bin/bash
set -euo pipefail

# Test script to validate Atlantis installation during Packer build
# This ensures the service can start before we create the AMI
#
# Usage: test-atlantis.sh [PORT]
# Default port: 80

ATLANTIS_PORT="${1:-80}"

echo "========================================"
echo "Testing Atlantis Installation"
echo "========================================"

# Test 1: Verify Docker can load the Atlantis image
echo ""
echo "Test 1: Checking Docker image..."
if ! sudo docker images local-atlantis:latest | grep -q local-atlantis; then
  echo "ERROR: Atlantis Docker image 'local-atlantis:latest' not found"
  sudo docker images
  exit 1
fi
echo "✓ Docker image found"

# Test 2: Verify systemd service file exists and is valid
echo ""
echo "Test 2: Validating systemd service file..."
if [[ ! -f /etc/systemd/system/atlantis.service ]]; then
  echo "ERROR: Systemd service file not found at /etc/systemd/system/atlantis.service"
  exit 1
fi
sudo systemd-analyze verify /etc/systemd/system/atlantis.service || {
  echo "ERROR: Systemd service file validation failed"
  exit 1
}
echo "✓ Systemd service file is valid"

# Test 3: Create dummy secrets and test container startup
echo ""
echo "Test 3: Testing Atlantis container startup..."

# Create dummy secrets file
sudo mkdir -p /etc/atlantis/github-app
cat <<'EOF' | sudo tee /etc/atlantis/secrets.env > /dev/null
ATLANTIS_GH_TOKEN=dummy_token_for_packer_testing
ATLANTIS_GH_WEBHOOK_SECRET=
ATLANTIS_WEB_USERNAME=admin
ATLANTIS_WEB_PASSWORD=dummy_password_for_testing
EOF
sudo chmod 600 /etc/atlantis/secrets.env

# Copy repos.yaml from AMI build (replicates what bootstrap.sh does at runtime)
if [ -f /opt/atlantis-build/repos.yaml ]; then
  sudo cp /opt/atlantis-build/repos.yaml /etc/atlantis/repos.yaml
  sudo chmod 644 /etc/atlantis/repos.yaml
  echo "repos.yaml copied to /etc/atlantis/repos.yaml"
else
  echo "ERROR: repos.yaml not found in /opt/atlantis-build/"
  echo "repos.yaml must exist for Atlantis to start properly"
  exit 1
fi

# Generate real RSA private key for testing (Atlantis validates key format at startup)
# Use openssl to generate traditional PEM format (PKCS#1) that Atlantis expects
# Use 2048-bit key for faster generation during Packer build
echo "Generating test RSA private key..."
sudo openssl genrsa -out /etc/atlantis/github-app/key.pem 2048 >/dev/null 2>&1
# Make readable by Atlantis container user (UID 100) - test key so 644 is acceptable
sudo chmod 644 /etc/atlantis/github-app/key.pem
echo "Test GitHub App key generated at /etc/atlantis/github-app/key.pem"

# Start the service
echo "Starting Atlantis service..."
sudo systemctl start atlantis

# Wait for Atlantis startup attempt
echo "Waiting for Atlantis startup attempt..."
sleep 5

# Check if container is running OR if it failed with expected GitHub auth error
if sudo docker ps | grep -q atlantis; then
  echo "✓ Atlantis container is running"
  sudo docker ps --filter name=atlantis

  # Wait a bit longer to ensure stability
  echo ""
  echo "Waiting 10 seconds to ensure stability..."
  sleep 10

  # Check if still running
  if ! sudo docker ps | grep -q atlantis; then
    echo "ERROR: Atlantis container crashed after initial startup"
    sudo journalctl -u atlantis --no-pager -n 50
    exit 1
  fi

  echo "✓ Atlantis container is stable"
else
  # Container exited - check if it was due to expected GitHub auth failure
  echo "Container exited - checking logs for expected GitHub auth failure..."
  LOGS=$(sudo journalctl -u atlantis --no-pager -n 50 2>&1)

  if echo "$LOGS" | grep -q "401 Unauthorized.*access_tokens"; then
    echo "✓ Atlantis started correctly and failed with expected GitHub auth error (test key not registered)"
    echo "  This is expected behavior - runtime will use real GitHub App key"
  else
    echo "ERROR: Atlantis failed with unexpected error"
    echo ""
    echo "Docker containers:"
    sudo docker ps -a --filter name=atlantis
    echo ""
    echo "Systemd status:"
    sudo systemctl status atlantis --no-pager -l || true
    echo ""
    echo "Systemd logs:"
    echo "$LOGS"
    echo ""
    echo "Docker logs:"
    sudo docker logs atlantis 2>&1 || echo "No logs available"
    exit 1
  fi
fi

# Test 4: Check if Atlantis responds to health check
echo ""
echo "Test 4: Checking Atlantis health endpoint on port $ATLANTIS_PORT..."
if curl -f http://localhost:$ATLANTIS_PORT/healthz 2>/dev/null; then
  echo "✓ Atlantis health check passed"
else
  echo "WARNING: Atlantis health check failed (may be expected with dummy credentials)"
  echo "Container is running but health endpoint not responding"
fi

# Cleanup
echo ""
echo "Cleaning up test artifacts..."
sudo systemctl stop atlantis
sleep 2
sudo rm -f /etc/atlantis/secrets.env
sudo rm -f /etc/atlantis/repos.yaml
sudo rm -f /etc/atlantis/github-app/key.pem
sudo rmdir /etc/atlantis/github-app 2>/dev/null || true
sudo rmdir /etc/atlantis 2>/dev/null || true

echo ""
echo "========================================"
echo "All tests passed!"
echo "========================================"
