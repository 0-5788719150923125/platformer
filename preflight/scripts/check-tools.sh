#!/usr/bin/env bash
# Check for CLI tool availability with flexible check types
# Reads JSON from stdin with structure:
# {
#   "tool-name": {
#     "type": "discrete" | "any",
#     "commands": ["command1", "command2", ...]
#   }
# }
# Output: JSON map of tool names to "true"/"false" strings

set -euo pipefail

# Function to check if a command exists
# Handles both single commands (e.g., "docker") and multi-word commands (e.g., "docker compose")
check_command() {
  local cmd="$1"

  # Try running the command with version/--version to verify it works
  if $cmd version >/dev/null 2>&1; then
    return 0
  elif $cmd --version >/dev/null 2>&1; then
    return 0
  elif command -v "$cmd" >/dev/null 2>&1; then
    # Fallback to command -v for simple commands
    return 0
  fi

  return 1
}

# Read JSON input from stdin
input=$(cat)

# Handle empty input - return empty object
if [[ -z "$input" || "$input" == "{}" || "$input" == "null" ]]; then
  echo "{}"
  exit 0
fi

# Parse tool names from JSON keys
tool_names=$(echo "$input" | jq -r 'keys[]' 2>/dev/null || echo "")

# If no tools to check, return empty object
if [[ -z "$tool_names" ]]; then
  echo "{}"
  exit 0
fi

result="{"

while IFS= read -r tool_name; do
  # Get check type and commands for this tool
  check_type=$(echo "$input" | jq -r ".\"$tool_name\".type")
  commands=$(echo "$input" | jq -r ".\"$tool_name\".commands[]")

  found="false"

  if [[ "$check_type" == "discrete" ]]; then
    # Discrete: check if the single command exists
    while IFS= read -r cmd; do
      if check_command "$cmd"; then
        found="true"
        break
      fi
    done <<< "$commands"
  elif [[ "$check_type" == "any" ]]; then
    # Any: check if any of the commands exist
    while IFS= read -r cmd; do
      if check_command "$cmd"; then
        found="true"
        break
      fi
    done <<< "$commands"
  fi

  result="$result\"$tool_name\":\"$found\","
done <<< "$tool_names"

# Remove trailing comma and close JSON
result="${result%,}}"
echo "$result"
