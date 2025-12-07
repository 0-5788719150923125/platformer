#!/bin/bash
# Install and configure Redis on Rocky Linux 9

set -e

echo "Starting Redis installation at $(date)"

# Install EPEL repository (required for Redis)
echo "Installing EPEL repository..."
dnf install -y epel-release

# Install Redis server
echo "Installing Redis..."
dnf install -y redis

# Configure Redis to listen on localhost only (secure default)
# For production, consider additional security: requirepass, firewall rules, etc.
echo "Configuring Redis..."
# Ensure Redis is bound to localhost for security
sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf

# Enable Redis to start on boot
echo "Enabling Redis service..."
systemctl enable redis

# Start Redis immediately
echo "Starting Redis service..."
systemctl start redis

# Verify Redis is running
if systemctl is-active --quiet redis; then
    echo "Redis successfully installed and running"
    systemctl status redis --no-pager
    redis-cli ping  # Should return "PONG"
else
    echo "ERROR: Redis failed to start"
    systemctl status redis --no-pager
    exit 1
fi

echo "Redis installation completed at $(date)"
echo "Redis is listening on localhost:6379"
