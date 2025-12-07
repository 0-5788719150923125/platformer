#!/usr/bin/env bash
# Query AWS Organizations API for AWS accounts
# Outputs: {"account-name": "account-id"} JSON format compatible with generate-matrix.sh
# Returns: 0 on success, 1 on failure

set -euo pipefail

# Function to log errors to stderr
log_error() {
    echo "Error: $*" >&2
}

# Check dependencies
for cmd in aws jq; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd is required but not installed"
        exit 1
    fi
done

# Query AWS Organizations API
echo "Querying AWS Organizations API..." >&2

orgs_result=$(aws organizations list-accounts --output json 2>&2) || {
    log_error "Failed to query AWS Organizations API"
    exit 1
}

# Validate response
if ! echo "$orgs_result" | jq -e '.Accounts' > /dev/null 2>&1; then
    log_error "Invalid response from AWS Organizations API"
    exit 1
fi

# Build account name -> ID map from active accounts
accounts_json=$(echo "$orgs_result" | jq -c '
    .Accounts
    | map(select(.Status == "ACTIVE"))
    | map({(.Name): .Id})
    | add // {}
')

# Validate output
if ! echo "$accounts_json" | jq -e '.' > /dev/null 2>&1; then
    log_error "Failed to generate valid JSON output"
    exit 1
fi

account_count=$(echo "$accounts_json" | jq 'keys | length')
echo "Successfully retrieved $account_count accounts from AWS Organizations" >&2

# Output result to stdout
echo "$accounts_json"
