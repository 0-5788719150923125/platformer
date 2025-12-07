#!/usr/bin/env bash
# Merge state fragments for local Terraform execution
# Usage: Called by Terraform external data source
# Input: JSON via stdin with {states_dir, states}
# Output: JSON with {config: "<json-encoded-merged-config>"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check dependencies
for cmd in yq jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        echo "Please install $cmd to use state loading" >&2
        exit 1
    fi
done

# Load shared deep merge function
source "${SCRIPT_DIR}/deep-merge.sh"

# Parse Terraform external data source input from stdin
eval "$(jq -r '@sh "STATES_DIR=\(.states_dir) STATES=\(.states)"')"

# Decode JSON array of state names
state_names=$(echo "$STATES" | jq -r '.[]')

# Initialize with empty object
merged_config="{}"

# Load and merge each state
while IFS= read -r state_name; do
    [[ -z "$state_name" ]] && continue

    # Try with and without .yaml extension
    state_file=""
    if [[ -f "${STATES_DIR}/${state_name}.yaml" ]]; then
        state_file="${STATES_DIR}/${state_name}.yaml"
    elif [[ -f "${STATES_DIR}/${state_name}" ]]; then
        state_file="${STATES_DIR}/${state_name}"
    else
        echo "Error: State file not found: ${state_name} (tried ${state_name}.yaml and ${state_name})" >&2
        exit 1
    fi

    # Load YAML and convert to JSON
    state_config=$(yq -c . "$state_file")

    # Deep merge into accumulated config
    if [[ "$merged_config" == "{}" ]]; then
        merged_config="$state_config"
    else
        merged_config=$(jq -n \
            --argjson base "$merged_config" \
            --argjson override "$state_config" \
            "$DEEP_MERGE"' [$base, $override] | deep_merge')
    fi
done <<< "$state_names"

# Return as Terraform external data source format
# External data sources require all values to be strings, so we JSON-encode the result
jq -n --argjson config "$merged_config" '{"config": ($config | tojson)}'
