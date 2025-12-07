#!/bin/bash
# Redis/Valkey Post-Install Validation Hook
# Ensures Redis/Valkey is healthy and synced after patching/reboot
set -e

SCRIPT_NAME="Redis/Valkey Validation"

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

# Check if service should be running
echo "[$SCRIPT_NAME] Checking if $DB_TYPE service is enabled..."
if ! systemctl is-enabled ${SERVICE_NAME}-server 2>/dev/null && \
   ! systemctl is-enabled ${SERVICE_NAME} 2>/dev/null; then
  echo "[$SCRIPT_NAME] $DB_TYPE service not enabled - skipping"
  echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 0
fi
echo "[$SCRIPT_NAME] $DB_TYPE service is enabled"

echo "[$SCRIPT_NAME] Waiting for $DB_TYPE to start..."

# Wait for database to respond to PING (timeout 120s)
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Sending PING to $DB_TYPE..."
  if $CLI_CMD ping 2>/dev/null | grep -q "PONG"; then
    echo "[$SCRIPT_NAME] $DB_TYPE responding to PING after ${ELAPSED}s"
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "[$SCRIPT_NAME] ERROR: $DB_TYPE failed to start within ${TIMEOUT}s"
  echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  exit 1
fi

# Check role and validate accordingly
echo "[$SCRIPT_NAME] Querying $DB_TYPE role..."
ROLE=$($CLI_CMD role 2>/dev/null | head -1 || echo "unknown")
echo "[$SCRIPT_NAME] Detected role: $ROLE"

if [ "$ROLE" = "slave" ]; then
  echo "[$SCRIPT_NAME] Instance is replica - checking replication status"

  # Wait for replication to be connected (timeout 120s)
  TIMEOUT=120
  ELAPSED=0
  echo "[$SCRIPT_NAME] Waiting for replication to connect (timeout: ${TIMEOUT}s)..."
  while [ $ELAPSED -lt $TIMEOUT ]; do
    echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Checking replication state..."
    REPL_STATE=$($CLI_CMD role 2>/dev/null | awk 'NR==4' || echo "")
    echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Replication state: '$REPL_STATE'"
    if [ "$REPL_STATE" = "connected" ]; then
      echo "[$SCRIPT_NAME] Replication connected after ${ELAPSED}s"
      break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done

  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "[$SCRIPT_NAME] ERROR: Replication failed to connect within ${TIMEOUT}s"
    echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    exit 1
  fi

elif [ "$ROLE" = "master" ]; then
  echo "[$SCRIPT_NAME] Instance is master - checking connected replicas"

  # Get number of connected replicas
  REPLICA_COUNT=$($CLI_CMD role 2>/dev/null | awk 'NR==2' || echo "0")
  echo "[$SCRIPT_NAME] Connected replicas: $REPLICA_COUNT"

  if [ "$REPLICA_COUNT" -eq 0 ]; then
    echo "[$SCRIPT_NAME] WARNING: No replicas connected (expected for single-instance setups)"
    echo "[$SCRIPT_NAME] === COMPLETED WITH WARNING at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    exit 2  # Warning - continue patching
  fi
fi

# Verify Sentinel sees this instance as healthy (if Sentinel is running)
echo "[$SCRIPT_NAME] Checking if Sentinel is running..."
SENTINEL_SERVICE="${SERVICE_NAME}-sentinel"
if systemctl is-active --quiet ${SENTINEL_SERVICE} 2>/dev/null; then
  echo "[$SCRIPT_NAME] Sentinel is active - checking health status"

  # Auto-detect Sentinel master name
  echo "[$SCRIPT_NAME] Auto-detecting Sentinel master name..."
  MASTER_NAME=$($CLI_CMD -p $SENTINEL_PORT SENTINEL masters 2>/dev/null | awk '/"name"$/ {getline; match($0, /"([^"]+)"/, arr); print arr[1]; exit}')
  if [ -z "$MASTER_NAME" ]; then
    echo "[$SCRIPT_NAME] WARNING: Could not detect Sentinel master name - skipping Sentinel health check"
  else
    echo "[$SCRIPT_NAME] Detected Sentinel master name: '$MASTER_NAME'"

    TIMEOUT=60
    ELAPSED=0
    echo "[$SCRIPT_NAME] Waiting for Sentinel to report instance as healthy (timeout: ${TIMEOUT}s)..."
    while [ $ELAPSED -lt $TIMEOUT ]; do
      echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Querying Sentinel master status..."
      # Check if Sentinel reports this instance without 'down' flags
      if $CLI_CMD -p $SENTINEL_PORT SENTINEL master "$MASTER_NAME" 2>/dev/null | grep -A1 "flags" | grep -qv "down"; then
        echo "[$SCRIPT_NAME] Sentinel reports instance as healthy after ${ELAPSED}s"
        break
      fi
      echo "[$SCRIPT_NAME] [${ELAPSED}s/${TIMEOUT}s] Instance still marked as down, waiting..."
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
      echo "[$SCRIPT_NAME] ERROR: Sentinel still reports instance as down after ${TIMEOUT}s"
      echo "[$SCRIPT_NAME] === FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
      exit 1
    fi
  fi
else
  echo "[$SCRIPT_NAME] Sentinel not running - skipping Sentinel health check"
fi

echo "[$SCRIPT_NAME] All validation checks passed"
echo "[$SCRIPT_NAME] === COMPLETED SUCCESSFULLY at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
exit 0
