#!/bin/bash
# Install Python 3.9 on Rocky Linux 8
# Required because Rocky 8 ships only Python 3.6 (platform-python), which is
# incompatible with Ansible core 2.17+ modules (require Python 3.7+)

set -e

echo "Starting Python 3.9 installation at $(date)"

# Python 3.9 is available in Rocky 8's AppStream repository.
# Also install the base python3 (3.6) package to provide /usr/bin/python3
# and the 'python3 >= 3.6' RPM capability that the company packages depend on
# (e.g., vendor-sidemodule-yum-plugin).
echo "Installing python3 and python39 from AppStream..."
dnf install -y python3 python39

# Verify installation
if command -v python3.9 &> /dev/null; then
    echo "Python 3.9 successfully installed"
    python3.9 --version
else
    echo "ERROR: Python 3.9 failed to install"
    exit 1
fi

echo "Python 3.9 installation completed at $(date)"
