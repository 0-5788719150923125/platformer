#!/bin/bash
# Install and configure AWS Systems Manager agent on Rocky Linux 9
# This allows the instance to register with SSM for management via DHMC

set -e

echo "Starting SSM agent installation at $(date)"

# Install SSM agent directly from AWS
# Rocky Linux 9 is RHEL-compatible, use the RHEL 9 package
echo "Downloading SSM agent RPM from AWS..."
dnf install -y "https://s3.us-east-2.amazonaws.com/amazon-ssm-us-east-2/latest/linux_amd64/amazon-ssm-agent.rpm"

# Enable SSM agent to start on boot
echo "Enabling SSM agent service..."
systemctl enable amazon-ssm-agent

# Start SSM agent immediately
echo "Starting SSM agent service..."
systemctl start amazon-ssm-agent

# Verify service is running
if systemctl is-active --quiet amazon-ssm-agent; then
    echo "SSM agent successfully installed and running"
    systemctl status amazon-ssm-agent --no-pager
else
    echo "ERROR: SSM agent failed to start"
    systemctl status amazon-ssm-agent --no-pager
    exit 1
fi

echo "SSM agent installation completed at $(date)"
echo "Instance should register with Systems Manager within 1-2 minutes"
