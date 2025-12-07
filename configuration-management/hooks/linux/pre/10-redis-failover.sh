#!/bin/bash
# Redis/Valkey Pre-Install Safety Hook
# Detects if Redis/Valkey is running as master and triggers failover before installation
set -e

SCRIPT_NAME="Redis/Valkey Failover Check"

echo "[$SCRIPT_NAME] === STARTING at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "[$SCRIPT_NAME] Hostname: $(hostname)"
echo "[$SCRIPT_NAME] Instance ID: $(ec2-metadata --instance-id 2>/dev/null | cut -d' ' -f2 || echo 'unknown')"

# Check if redis-cli or valkey-cli is installed
echo "[$SCRIPT_NAME] Checking for Redis or Valkey CLI..."
CLI_CMD=""
SERVICE_NAME=""
DB_TYPE=""
SENTINEL_PORT="26379"

if command -v redis-cli &>/dev/null; then
  CLI_CMD="redis-cli"
  SERVICE_NAME="redis"
  DB_TYPE="Redis"
  echo "[$SCRIPT_NAME] Redis detected: $(which redis-cli)"
elif command -v valkey-cli &>/dev/null; then
  CLI_CMD="valkey-cli"
  SERVICE_NAME="valkey"
  DB_TYPE="Valkey"
  echo "[$SCRIPT_NAME] Valkey detected: $(which valkey-cli)"
else
  echo "[$SCRIPT_NAME] Neither Redis nor Valkey installed - skipping"
  echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 0
fi

# Check if service is running (check both common service names)
echo "[$SCRIPT_NAME] Checking if $DB_TYPE service is running..."
if ! systemctl is-active --quiet ${SERVICE_NAME}-server 2>/dev/null && \
   ! systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
  echo "[$SCRIPT_NAME] $DB_TYPE service not running - skipping"
  echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 0
fi
echo "[$SCRIPT_NAME] $DB_TYPE service is active"

# Determine role
echo "[$SCRIPT_NAME] Querying $DB_TYPE role..."
ROLE=$($CLI_CMD role 2>/dev/null | head -1 || echo "unknown")
echo "[$SCRIPT_NAME] Detected role: $ROLE"

if [ "$ROLE" = "unknown" ]; then
  echo "[$SCRIPT_NAME] Could not determine Redis role - skipping"
  echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 0
fi

if [ "$ROLE" = "master" ]; then
  echo "[$SCRIPT_NAME] Master detected - checking replication status"

  # Check if this is a standalone instance or part of a cluster
  echo "[$SCRIPT_NAME] Querying replication info..."
  CONNECTED_SLAVES=$($CLI_CMD info replication 2>/dev/null | grep "^connected_slaves:" | cut -d: -f2 | tr -d '\r')
  echo "[$SCRIPT_NAME] Connected slaves count: '${CONNECTED_SLAVES}' (empty or 0 means standalone)"

  if [ -z "$CONNECTED_SLAVES" ] || [ "$CONNECTED_SLAVES" = "0" ]; then
    echo "[$SCRIPT_NAME] Standalone master (no replicas) - safe to patch"
    echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    exit 0
  fi

  echo "[$SCRIPT_NAME] Master with $CONNECTED_SLAVES replica(s) - checking for Sentinel"

  # Check if Sentinel is available
  echo "[$SCRIPT_NAME] Checking for Sentinel on port $SENTINEL_PORT..."
  if ! $CLI_CMD -p $SENTINEL_PORT ping 2>/dev/null | grep -q "PONG"; then
    echo "[$SCRIPT_NAME] ERROR: Master with replicas but no Sentinel available"
    echo "[$SCRIPT_NAME] Cannot safely failover - manual intervention required"
    echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    exit 1
  fi
  echo "[$SCRIPT_NAME] Sentinel is available and responding"

  # Auto-detect Sentinel master name
  echo "[$SCRIPT_NAME] Auto-detecting Sentinel master name..."
  MASTER_NAME=$($CLI_CMD -p $SENTINEL_PORT SENTINEL masters 2>/dev/null | awk '/"name"$/ {getline; match($0, /"([^"]+)"/, arr); print arr[1]; exit}')
  if [ -z "$MASTER_NAME" ]; then
    echo "[$SCRIPT_NAME] ERROR: Could not detect Sentinel master name"
    echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    exit 1
  fi
  echo "[$SCRIPT_NAME] Detected Sentinel master name: '$MASTER_NAME'"

  echo "[$SCRIPT_NAME] Triggering Sentinel failover for '$MASTER_NAME'..."

  # Trigger Sentinel failover
  if ! $CLI_CMD -p $SENTINEL_PORT SENTINEL failover "$MASTER_NAME" 2>/dev/null; then
    echo "[$SCRIPT_NAME] ERROR: Failover command failed"
    echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    exit 1
  fi
  echo "[$SCRIPT_NAME] Failover command sent successfully"

  # Wait for demotion to replica (timeout 60s)
  TIMEOUT=60
  ELAPSED=0
  echo "[$SCRIPT_NAME] Waiting for demotion to replica (timeout: ${TIMEOUT}s)..."
  while [ $ELAPSED -lt $TIMEOUT ]; do
    echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Checking current role..."
    CURRENT_ROLE=$($CLI_CMD role 2>/dev/null | head -1 || echo "unknown")
    echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Current role: $CURRENT_ROLE"
    if [ "$CURRENT_ROLE" = "slave" ]; then
      echo "[$SCRIPT_NAME] Successfully demoted to replica after ${ELAPSED}s"
      echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  done

  echo "[$SCRIPT_NAME] ERROR: Timeout waiting for demotion to replica"
  echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 1
else
  echo "[$SCRIPT_NAME] Current role: $ROLE - safe to patch"
  echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
fi

exit 0
