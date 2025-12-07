#!/bin/bash
# Install AWS CLI v2 on Rocky Linux 9
# Required by patch lifecycle hooks for Systems Manager

set -e

echo "Starting AWS CLI installation at $(date)"

# Install prerequisites (unzip)
echo "Installing prerequisites..."
dnf install -y unzip

# Download and install AWS CLI v2
echo "Downloading AWS CLI v2..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"

echo "Installing AWS CLI v2..."
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Cleanup
echo "Cleaning up temporary files..."
rm -rf /tmp/awscliv2.zip /tmp/aws

# Verify installation
if command -v aws &> /dev/null; then
    echo "AWS CLI successfully installed"
    aws --version
else
    echo "ERROR: AWS CLI failed to install"
    exit 1
fi

echo "AWS CLI installation completed at $(date)"
