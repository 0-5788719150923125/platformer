#!/usr/bin/env bash
# Merge fragments for local Terraform execution
# Usage: Called by Terraform external data source
# Input: JSON via stdin with {fragments_dir, fragments}
# Output: JSON with {config: "<json-encoded-merged-config>"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check dependencies
for cmd in yq jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        echo "Please install $cmd to use fragment loading" >&2
        exit 1
    fi
done

# Load shared deep merge function
source "${SCRIPT_DIR}/deep-merge.sh"

# Parse Terraform external data source input from stdin
eval "$(jq -r '@sh "FRAGMENTS_DIR=\(.fragments_dir) FRAGMENTS=\(.fragments)"')"

# Decode JSON array of fragment names
fragment_names=$(echo "$FRAGMENTS" | jq -r '.[]')

# Initialize with empty object
merged_config="{}"

# Load and merge each fragment
while IFS= read -r fragment_name; do
    [[ -z "$fragment_name" ]] && continue

    # Try with and without .yaml extension
    fragment_file=""
    if [[ -f "${FRAGMENTS_DIR}/${fragment_name}.yaml" ]]; then
        fragment_file="${FRAGMENTS_DIR}/${fragment_name}.yaml"
    elif [[ -f "${FRAGMENTS_DIR}/${fragment_name}" ]]; then
        fragment_file="${FRAGMENTS_DIR}/${fragment_name}"
    else
        echo "Error: fragment not found: ${fragment_name} (tried ${fragment_name}.yaml and ${fragment_name})" >&2
        exit 1
    fi

    # Load YAML and convert to JSON
    fragment_config=$(yq -c . "$fragment_file")

    # Deep merge into accumulated config
    if [[ "$merged_config" == "{}" ]]; then
        merged_config="$fragment_config"
    else
        merged_config=$(jq -n \
            --argjson base "$merged_config" \
            --argjson override "$fragment_config" \
            "$DEEP_MERGE"' [$base, $override] | deep_merge')
    fi
done <<< "$fragment_names"

# Return as Terraform external data source format
# External data sources require all values to be strings, so we JSON-encode the result
jq -n --argjson config "$merged_config" '{"config": ($config | tojson)}'
