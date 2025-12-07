#!/bin/bash
set -e

# Usage: manage-docker-compose.sh <up|down> <compose_dir> <namespace> [env_file] [env_vars...]
#
# Manages Docker Compose services with automatic detection of compose command
# (docker compose vs docker-compose)
#
# Arguments:
#   action: "up" or "down"
#   compose_dir: Path to directory containing docker-compose.yml
#   namespace: Namespace for container naming
#   env_file: (optional) Path to .env file with sensitive variables
#   env_vars: (optional) Additional KEY=VALUE environment variables

ACTION=$1
COMPOSE_DIR=$2
NAMESPACE=$3
ENV_FILE=$4

# Shift past the first 4 arguments so remaining args are environment variables
shift 4 2>/dev/null || true

# Convert relative paths to absolute before changing directory
if [ -n "$ENV_FILE" ] && [[ ! "$ENV_FILE" = /* ]]; then
  ENV_FILE="$(pwd)/$ENV_FILE"
fi
if [[ ! "$COMPOSE_DIR" = /* ]]; then
  COMPOSE_DIR="$(pwd)/$COMPOSE_DIR"
fi

# Detect which docker compose command is available
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  echo "Using: docker compose (v2)" >&2
elif docker-compose --version >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
  echo "Using: docker-compose (v1)" >&2
else
  echo "Error: Neither 'docker compose' nor 'docker-compose' is available" >&2
  echo "Please install Docker Compose: https://docs.docker.com/compose/install/" >&2
  exit 1
fi

# Change to compose directory
cd "$COMPOSE_DIR"

if [ "$ACTION" == "up" ]; then
  echo "Starting Docker Compose services in $COMPOSE_DIR..." >&2

  # Copy env file to .env in compose directory (referenced by env_file in compose.yml)
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    echo "Copying environment file to $COMPOSE_DIR/.env..." >&2
    cp "$ENV_FILE" "$COMPOSE_DIR/.env"
    chmod 600 "$COMPOSE_DIR/.env"
  fi

  # Export all remaining arguments as environment variables (for ${VAR} substitution in compose.yml)
  # They should be in the format KEY=VALUE (for non-sensitive values)
  for var in "$@"; do
    export "$var"
  done

  # Start services (compose.yml references .env via env_file)
  $COMPOSE_CMD up -d --build

  # Clean up .env file after compose starts
  if [ -f "$COMPOSE_DIR/.env" ]; then
    rm -f "$COMPOSE_DIR/.env"
    echo "Environment loaded and cleaned up" >&2
  fi

  # Clean up the original Terraform env file
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
  fi

  echo "Docker Compose services started successfully" >&2
  echo "Container prefix: platformer-port-*-${NAMESPACE}" >&2

elif [ "$ACTION" == "down" ]; then
  echo "Stopping Docker Compose services in $COMPOSE_DIR..." >&2

  # Export variables for docker-compose.yml substitution (suppresses warnings)
  export NAMESPACE="$NAMESPACE"
  export AWS_PROFILE="${AWS_PROFILE:-}"
  export AWS_REGION="${AWS_REGION:-}"
  export TERRAFORM_WORKSPACE="${TERRAFORM_WORKSPACE:-default}"

  # Stop and remove services
  $COMPOSE_CMD down

  echo "Docker Compose services stopped successfully" >&2

else
  echo "Invalid action: $ACTION. Use 'up' or 'down'" >&2
  exit 1
fi
