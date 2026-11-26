#!/usr/bin/env bash
# Generate GitHub Actions matrix from top.yaml and Port API
# Usage: ./generate-matrix.sh > matrix.json
# Note: This script is for CI/CD only. Local developers use terraform.tfvars directly.
# Requirements: yq (python-based), jq, aws-cli, curl
# AWS Permissions: sts:AssumeRole (for cross_account_admin), secretsmanager:GetSecretValue
# Pattern Matching: Case-insensitive glob patterns (e.g., '*-Platform-Dev' matches 'my-platform-dev')

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_FILE="${SCRIPT_DIR}/../top.yaml"
FRAGMENTS_DIR="${SCRIPT_DIR}/../fragments"
ACCOUNTS_FILE="${SCRIPT_DIR}/../accounts.json"

# Check dependencies
for cmd in yq jq aws; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        exit 1
    fi
done

# Validate files exist
declare -A validations=(
    ["$TOP_FILE"]="file:top.yaml not found at"
    ["$FRAGMENTS_DIR"]="dir:fragments directory not found at"
)

for path in "${!validations[@]}"; do
    IFS=: read -r type msg <<< "${validations[$path]}"
    if [[ "$type" == "file" && ! -f "$path" ]] || [[ "$type" == "dir" && ! -d "$path" ]]; then
        echo "Error: $msg $path" >&2
        exit 1
    fi
done

# Load shared deep merge function
source "${SCRIPT_DIR}/deep-merge.sh"

# Function to check if account name matches a compound pattern
# Supports: 'pattern1 or pattern2' and 'pattern1 and pattern2'
# Args: $1 = account name, $2 = pattern (may contain 'or'/'and' operators)
# Returns: 0 if match, 1 if no match
matches_pattern() {
    local account_name="$1"
    local pattern="$2"

    # Normalize to lowercase for case-insensitive matching
    local account_lower="${account_name,,}"
    local pattern_lower="${pattern,,}"

    # Split by ' or ' to get OR groups (case-insensitive)
    IFS='|' read -ra or_groups <<< "$(echo "$pattern_lower" | sed 's/ or /|/g')"

    # Check each OR group - if ANY matches, return true
    for or_group in "${or_groups[@]}"; do
        # Trim whitespace
        or_group="$(echo "$or_group" | xargs)"

        # Split by ' and ' to get AND sub-patterns
        IFS='|' read -ra and_patterns <<< "$(echo "$or_group" | sed 's/ and /|/g')"

        # Check if ALL AND patterns match
        local all_match=true
        for and_pattern in "${and_patterns[@]}"; do
            # Trim whitespace
            and_pattern="$(echo "$and_pattern" | xargs)"

            # Check if account matches this sub-pattern
            case "$account_lower" in
                $and_pattern) ;; # matches
                *) all_match=false; break ;;
            esac
        done

        # If all AND patterns matched, this OR group matches
        if [[ "$all_match" == "true" ]]; then
            return 0
        fi
    done

    # No OR groups matched
    return 1
}

# Function to resolve fragment references into merged configuration
# Args: $1 = JSON array of fragment names (e.g., ["regions-multi-east", "configuration-management"])
# Returns: Merged JSON configuration object
resolve_fragments() {
    local fragment_refs="$1"
    local merged_config="{}"

    # Extract fragment names from array
    local fragment_names=$(echo "$fragment_refs" | jq -r '.[]')

    while IFS= read -r fragment_name; do
        [[ -z "$fragment_name" ]] && continue

        # Try with and without .yaml extension
        local fragment_file=""
        if [[ -f "${FRAGMENTS_DIR}/${fragment_name}.yaml" ]]; then
            fragment_file="${FRAGMENTS_DIR}/${fragment_name}.yaml"
        elif [[ -f "${FRAGMENTS_DIR}/${fragment_name}" ]]; then
            fragment_file="${FRAGMENTS_DIR}/${fragment_name}"
        else
            echo "Error: fragment not found: ${fragment_name} (tried ${fragment_name}.yaml and ${fragment_name})" >&2
            exit 1
        fi

        # Load fragment YAML and convert to JSON
        local fragment_config=$(yq -c . "$fragment_file")

        # Merge with accumulated config using generic deep merge
        if [[ "$merged_config" == "{}" ]]; then
            merged_config="$fragment_config"
        else
            merged_config=$(jq -n --argjson base "$merged_config" --argjson override "$fragment_config" "$DEEP_MERGE"' [$base, $override] | deep_merge')
        fi
    done <<< "$fragment_names"

    echo "$merged_config"
}

# Convert entire YAML to JSON once for easier processing
targets_json=$(yq -c . "$TOP_FILE")

# Fetch accounts with fallback chain: Port API → AWS Organizations → accounts.json
accounts_json=""

# Attempt 1: Try Port API (with cross_account_admin or local credentials)
echo "Fetching accounts from Port API..." >&2
if port_result=$(bash "${SCRIPT_DIR}/query-port-accounts.sh" 2>&2); then
    # Port API succeeded - validate output
    if echo "$port_result" | jq -e '.' > /dev/null 2>&1 && [[ $(echo "$port_result" | jq 'keys | length') -gt 0 ]]; then
        accounts_json="$port_result"
        echo "Successfully fetched $(echo "$accounts_json" | jq 'keys | length') accounts from Port API" >&2

        # Save to accounts.json for future use (only when running locally)
        if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
            echo "$accounts_json" | jq '.' > "$ACCOUNTS_FILE"
            echo "Saved to accounts.json" >&2
        fi
    fi
fi

# Attempt 2: If Port API failed, try AWS Organizations API
if [[ -z "$accounts_json" ]]; then
    echo "Port API failed, trying AWS Organizations API..." >&2

    if orgs_result=$(bash "${SCRIPT_DIR}/query-organizations-accounts.sh" 2>&2); then
        # Organizations API succeeded - validate output
        if echo "$orgs_result" | jq -e '.' > /dev/null 2>&1 && [[ $(echo "$orgs_result" | jq 'keys | length') -gt 0 ]]; then
            accounts_json="$orgs_result"
            echo "Successfully fetched $(echo "$accounts_json" | jq 'keys | length') accounts from AWS Organizations API" >&2

            # Save to accounts.json for future use (only when running locally)
            if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
                echo "$accounts_json" | jq '.' > "$ACCOUNTS_FILE"
                echo "Saved to accounts.json" >&2
            fi
        fi
    fi
fi

# Attempt 3: If both APIs failed, fall back to accounts.json
if [[ -z "$accounts_json" ]]; then
    echo "Both Port API and AWS Organizations API failed, falling back to accounts.json..." >&2

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        echo "Error: accounts.json not found at $ACCOUNTS_FILE" >&2
        echo "All account discovery methods failed:" >&2
        echo "  1. Port API - failed" >&2
        echo "  2. AWS Organizations API - failed" >&2
        echo "  3. accounts.json - not found" >&2
        exit 1
    fi

    accounts_json=$(cat "$ACCOUNTS_FILE")
    echo "Loaded $(echo "$accounts_json" | jq 'keys | length') accounts from accounts.json" >&2
fi

# Extract account names
accounts=$(echo "$accounts_json" | jq -r 'keys | .[]')

echo "Processing $(echo "$accounts" | wc -l | tr -d ' ') active accounts" >&2

# Initialize matrix array
matrix="[]"

# Process each account
while IFS= read -r account_name; do
    [[ -z "$account_name" ]] && continue

    # Look up account ID from fetched accounts
    account_id=$(echo "$accounts_json" | jq -r ".[\"$account_name\"]")

    # Collect fragment names to pass to Terraform (not resolved here)
    # Start with base fragments ('*') if it exists, otherwise empty array
    fragments_array="[]"
    base_target=$(echo "$targets_json" | jq '.targets["*"] // null')
    if [[ "$base_target" != "null" && $(echo "$base_target" | jq 'type') == '"array"' ]]; then
        fragments_array="$base_target"
    fi

    # Get all target patterns (except '*'), in order from file
    patterns=$(echo "$targets_json" | jq -r '.targets | keys_unsorted | .[] | select(. != "*")')

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue

        # Check if account matches pattern (supports compound matching: 'or', 'and')
        if matches_pattern "$account_name" "$pattern"; then
            # Pattern matches - append fragment names to array
            pattern_target=$(echo "$targets_json" | jq ".targets[\"$pattern\"]")

            # Only process array (state references), not direct config objects
            if [[ $(echo "$pattern_target" | jq 'type') == '"array"' ]]; then
                # Append pattern fragments to accumulated fragments array
                fragments_array=$(jq -n --argjson base "$fragments_array" --argjson new "$pattern_target" '$base + $new')
            fi
        fi
    done <<< "$patterns"

    # Skip account if no fragments matched
    if [[ "$fragments_array" == "[]" ]]; then
        continue
    fi

    # Resolve fragments ONLY to extract matrix config (not for services config)
    # Terraform's config module will do the authoritative merge
    config=$(resolve_fragments "$fragments_array")

    # Skip if resolved config is empty
    if [[ "$config" == "{}" ]]; then
        continue
    fi

    # Extract regions from merged matrix config
    # Handle null/missing regions gracefully (skip account if no regions defined)
    regions=$(echo "$config" | jq -r '.matrix.regions[]? // empty')

    # Skip account if no regions are defined after merging fragments
    if [[ -z "$regions" ]]; then
        continue
    fi

    # Cross-product: account × regions = matrix entries
    # Output fragments array (not pre-merged services) - Terraform config module handles merging
    while IFS= read -r region; do
        [[ -z "$region" ]] && continue

        entry=$(jq -n \
            --arg account_name "$account_name" \
            --arg account_id "$account_id" \
            --arg region "$region" \
            --argjson fragments "$fragments_array" \
            '{account_name: $account_name, account_id: $account_id, region: $region, fragments: $fragments}')

        matrix=$(echo "$matrix" | jq --argjson entry "$entry" '. += [$entry]')
    done <<< "$regions"
done <<< "$accounts"

# Output final matrix
echo "$matrix" | jq -c '.'
