#!/bin/bash
# Install Ansible for local playbook execution
# Supports: Rocky Linux 9, Amazon Linux 2023

set -e

echo "Starting Ansible installation at $(date)"

# Check if Ansible is already installed
if command -v ansible-playbook &> /dev/null; then
    echo "Ansible is already installed: $(ansible-playbook --version | head -n1)"
    exit 0
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo "ERROR: Cannot detect OS"
    exit 1
fi

echo "Detected OS: $OS $VERSION"

# Install Ansible based on OS
case "$OS" in
    rocky)
        echo "Installing Ansible on Rocky Linux..."
        # Install EPEL repository (required for Ansible)
        dnf install -y epel-release
        # Install Ansible and required Python dependencies
        dnf install -y \
            ansible-core \
            python3-boto3 \
            python3-botocore \
            python3-pip
        ;;
    amzn)
        echo "Installing Ansible on Amazon Linux..."
        # Amazon Linux 2023 doesn't have ansible-core in default repos
        # Install via pip instead
        dnf install -y python3-pip
        pip3 install --user ansible-core boto3 botocore
        # Add pip user bin to PATH for current session (use /root explicitly since $HOME might not be set)
        export PATH="/root/.local/bin:$PATH"
        # Add to system-wide profile for future sessions
        echo 'export PATH="/root/.local/bin:$PATH"' >> /etc/profile.d/ansible.sh
        # Create symlinks in /usr/local/bin so SSM can find ansible commands
        # SSM doesn't source /etc/profile.d/ scripts, so PATH changes don't work
        for cmd in /root/.local/bin/ansible*; do
            if [ -f "$cmd" ]; then
                ln -sf "$cmd" "/usr/local/bin/$(basename $cmd)"
            fi
        done
        ;;
    ubuntu)
        echo "Installing Ansible on Ubuntu..."
        # Ubuntu 24.04 has PEP 668 protection that blocks pip global installs
        # Install Ansible from Ubuntu repos instead

        # Use apt-get's built-in lock timeout (waits up to 300 seconds for locks)
        # This handles race conditions with unattended-upgrades on first boot
        apt-get -o DPkg::Lock::Timeout=300 update -qq
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y \
            ansible \
            python3-boto3 \
            python3-botocore
        ;;
    *)
        echo "ERROR: Unsupported OS: $OS"
        exit 1
        ;;
esac

# Verify Ansible installation
if ansible-playbook --version > /dev/null 2>&1; then
    echo "Ansible successfully installed"
    ansible-playbook --version
else
    echo "ERROR: Ansible installation failed"
    exit 1
fi

echo "Ansible installation completed at $(date)"
