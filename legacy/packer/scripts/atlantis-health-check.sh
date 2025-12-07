#!/bin/bash
set -euo pipefail

# Health check script for Atlantis
# Arguments:
#   $1 - Port (optional, defaults to 80)

PORT="${1:-80}"

for i in {1..30}; do
  if curl -f "http://localhost:${PORT}/healthz" 2>/dev/null; then
    echo "Atlantis is healthy"
    exit 0
  fi
  echo "Waiting for Atlantis... ($i/30)"
  sleep 10
done

echo "Atlantis failed to become healthy"
exit 1
