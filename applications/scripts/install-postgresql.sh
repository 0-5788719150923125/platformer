#!/bin/bash
# Install PostgreSQL on Rocky Linux 9 or Amazon Linux 2023
# Parameters (via environment variables):
#   POSTGRES_VERSION - PostgreSQL version (default: 15)

set -e

POSTGRES_VERSION=${POSTGRES_VERSION:-15}

echo "Installing PostgreSQL $POSTGRES_VERSION..."

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "Cannot detect OS"
  exit 1
fi

# Set package name based on OS
if [ "$OS" = "rocky" ]; then
  PACKAGE="postgresql${POSTGRES_VERSION}-server"
  SERVICE="postgresql-${POSTGRES_VERSION}"

  # Idempotent check for Rocky
  if rpm -q $PACKAGE &>/dev/null; then
    echo "$PACKAGE already installed"
    systemctl is-active --quiet $SERVICE && echo "PostgreSQL service is running" || systemctl start $SERVICE
    exit 0
  fi

  # Add PostgreSQL repository for Rocky Linux
  echo "Adding PostgreSQL repository for Rocky Linux..."
  dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm

  # Disable built-in PostgreSQL module to use PostgreSQL repo
  dnf -qy module disable postgresql

  # Install package
  echo "Installing $PACKAGE..."
  dnf install -y $PACKAGE

  # Initialize database (Rocky uses versioned path)
  if [ ! -d "/var/lib/pgsql/${POSTGRES_VERSION}/data/base" ]; then
    echo "Initializing PostgreSQL database..."
    /usr/pgsql-${POSTGRES_VERSION}/bin/postgresql-${POSTGRES_VERSION}-setup initdb
  fi

elif [ "$OS" = "amzn" ]; then
  PACKAGE="postgresql${POSTGRES_VERSION}-server"
  SERVICE="postgresql"

  # Idempotent check for Amazon Linux
  if rpm -q $PACKAGE &>/dev/null; then
    echo "$PACKAGE already installed"
    systemctl is-active --quiet $SERVICE && echo "PostgreSQL service is running" || systemctl start $SERVICE
    exit 0
  fi

  # Install package (Amazon Linux 2023 has it in default repos)
  echo "Installing $PACKAGE..."
  dnf install -y $PACKAGE

  # Initialize database
  if [ ! -d "/var/lib/pgsql/data/base" ]; then
    echo "Initializing PostgreSQL database..."
    postgresql-setup --initdb
  fi
else
  echo "Unsupported OS: $OS"
  exit 1
fi

# Enable and start service
echo "Enabling and starting PostgreSQL service..."
systemctl enable $SERVICE
systemctl start $SERVICE

# Verify
echo "Verifying PostgreSQL installation..."
systemctl is-active --quiet $SERVICE && echo "PostgreSQL is running successfully" || exit 1
echo "Installation complete"
