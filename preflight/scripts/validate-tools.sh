#!/usr/bin/env bash
# Validate tool check results and fail if any required tools are missing
# Takes two arguments:
#   $1 - JSON string of tool check results (e.g., {"docker":"true","packer":"false"})
#   $2 - JSON string of tool definitions (e.g., {"docker":{"type":"discrete","commands":["docker"]}})

set -euo pipefail

results="$1"
tools="$2"

# Handle empty inputs - nothing to validate
if [[ -z "$tools" || "$tools" == "{}" || "$tools" == "null" ]]; then
  echo "{}"
  exit 0
fi

failed=()

# Check each tool result
for tool in $(echo "$tools" | jq -r 'keys[]' 2>/dev/null || echo ""); do
  [[ -z "$tool" ]] && continue

  status=$(echo "$results" | jq -r ".[\"$tool\"]")
  if [[ "$status" != "true" ]]; then
    type=$(echo "$tools" | jq -r ".[\"$tool\"].type")
    commands=$(echo "$tools" | jq -r ".[\"$tool\"].commands | join(\", \")")

    if [[ "$type" == "discrete" ]]; then
      failed+=("$tool: command not found in PATH")
    else
      failed+=("$tool: none of [$commands] found in PATH")
    fi
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "ERROR: Required tools missing:" >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi

echo "{}"
