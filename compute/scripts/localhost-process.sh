#!/usr/bin/env bash
set -euo pipefail

# Backgrounds a command (LOCALHOST_CMD env var) so Terraform doesn't block.
# Cleanup is handled by the application's own stop command (STOP_CMD),
# not by process-level kills.

LOG_FILE="${1:?Usage: localhost-process.sh LOG_FILE}"

mkdir -p "$(dirname "$LOG_FILE")"

# Launch in new session (detached from Terraform)
setsid bash -c 'eval "$LOCALHOST_CMD"' > "$LOG_FILE" 2>&1 &

# Brief settle, then verify process is running
sleep 2
if jobs -l | grep -q Running; then
  echo "Process started (log: $LOG_FILE)"
else
  echo "ERROR: Process exited immediately" >&2
  tail -20 "$LOG_FILE" >&2 || true
  exit 1
fi
