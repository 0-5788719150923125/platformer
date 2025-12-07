#!/bin/bash
set -euo pipefail

# Bootstrap script for Atlantis EC2 instance
# Parses consolidated JSON secret and sets up GitHub App authentication

echo "Starting Atlantis bootstrap..."

# Parse JSON secret passed from Terraform (jq handles \n escape sequences automatically)
GITHUB_APP_KEY=$(echo '${atlantis_secrets_json}' | jq -r '.github_app_key')
GITHUB_WEBHOOK_SECRET=$(echo '${atlantis_secrets_json}' | jq -r '.github_webhook_secret')

# Web username from Terraform config (not a secret)
WEB_USERNAME="${web_username}"

# Create directory structure
mkdir -p /etc/atlantis/github-app

# Write GitHub App private key to file (jq already decoded \n to actual newlines)
echo "$GITHUB_APP_KEY" > /etc/atlantis/github-app/key.pem
chown 100:100 /etc/atlantis/github-app/key.pem
chmod 600 /etc/atlantis/github-app/key.pem
echo "GitHub App key written to /etc/atlantis/github-app/key.pem"

# Copy repos.yaml from AMI build (baked in by Packer)
if [ -f /opt/atlantis-build/repos.yaml ]; then
  cp /opt/atlantis-build/repos.yaml /etc/atlantis/repos.yaml
  chmod 644 /etc/atlantis/repos.yaml
  echo "repos.yaml copied to /etc/atlantis/repos.yaml"
else
  echo "WARNING: repos.yaml not found in /opt/atlantis-build/ - will use Atlantis defaults"
fi

# Create environment file for secrets read by start-atlantis.sh
cat > /etc/atlantis/secrets.env <<EOF
ATLANTIS_GH_WEBHOOK_SECRET=$${GITHUB_WEBHOOK_SECRET}
ATLANTIS_WEB_USERNAME=$${WEB_USERNAME}
ATLANTIS_WEB_PASSWORD=${web_password}
EOF

# Set secure permissions
chmod 600 /etc/atlantis/secrets.env
echo "Secrets file created at /etc/atlantis/secrets.env"

# Start or restart Atlantis service
if systemctl is-active --quiet atlantis; then
  echo "Restarting Atlantis service..."
  systemctl restart atlantis
else
  echo "Starting Atlantis service..."
  systemctl start atlantis
fi

echo "Bootstrap complete - Atlantis should be starting now"
