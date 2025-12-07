#!/usr/bin/env bash
# Query Port API for AWS accounts
# Outputs: {"account-name": "account-id"} JSON format compatible with generate-matrix.sh
# Returns: 0 on success, 1 on failure

set -euo pipefail

PORT_API_BASE="https://api.us.getport.io/v1"
SECRET_ARN="arn:aws:secretsmanager:us-east-2:111111111111:secret:github/port/credentials-1fuTMB"
CROSS_ACCOUNT_ROLE="arn:aws:iam::111111111111:role/cross_account_admin"

# Function to log errors to stderr
log_error() {
    echo "Error: $*" >&2
}

# Check dependencies
for cmd in aws jq curl; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd is required but not installed"
        exit 1
    fi
done

# Try to get Port credentials - first with cross_account_admin role, then with local credentials
secret_value=""
role_assumed=false

# Attempt 1: Try assuming cross_account_admin role
echo "Attempting to assume cross_account_admin role..." >&2
if assume_output=$(aws sts assume-role \
    --role-arn "$CROSS_ACCOUNT_ROLE" \
    --role-session-name "port-accounts-query" \
    --query 'Credentials' \
    --output json 2>/dev/null); then

    if echo "$assume_output" | jq -e '.AccessKeyId' > /dev/null 2>&1; then
        echo "Successfully assumed cross_account_admin role" >&2
        role_assumed=true

        # Export temporary credentials
        export AWS_ACCESS_KEY_ID=$(echo "$assume_output" | jq -r '.AccessKeyId')
        export AWS_SECRET_ACCESS_KEY=$(echo "$assume_output" | jq -r '.SecretAccessKey')
        export AWS_SESSION_TOKEN=$(echo "$assume_output" | jq -r '.SessionToken')

        # Try to fetch secret with assumed role
        echo "Fetching Port credentials from Secrets Manager (using assumed role)..." >&2
        secret_value=$(aws secretsmanager get-secret-value \
            --secret-id "$SECRET_ARN" \
            --region us-east-2 \
            --query 'SecretString' \
            --output text 2>/dev/null) || true
    fi
fi

# Attempt 2: If role assumption failed or secret fetch failed, try with local credentials
if [[ -z "$secret_value" ]]; then
    if [[ "$role_assumed" == "true" ]]; then
        echo "Failed to fetch secret with assumed role, trying local credentials..." >&2
        # Clear the assumed role credentials
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    else
        echo "Role assumption failed, trying with local credentials..." >&2
    fi

    # Try with local credentials
    secret_value=$(aws secretsmanager get-secret-value \
        --secret-id "$SECRET_ARN" \
        --region us-east-2 \
        --query 'SecretString' \
        --output text 2>/dev/null) || true

    if [[ -z "$secret_value" ]]; then
        log_error "Failed to fetch Port credentials with both assumed role and local credentials"
        log_error "Ensure you have access to: $SECRET_ARN"
        exit 1
    fi

    echo "Successfully fetched Port credentials using local credentials" >&2
fi

# Extract credentials (try multiple possible key names)
PORT_CLIENT_ID=$(echo "$secret_value" | jq -r '.CLIENT_ID // .clientId // .client_id // empty')
PORT_CLIENT_SECRET=$(echo "$secret_value" | jq -r '.CLIENT_SECRET // .clientSecret // .client_secret // empty')

if [[ -z "$PORT_CLIENT_ID" || -z "$PORT_CLIENT_SECRET" ]]; then
    log_error "Failed to extract CLIENT_ID or CLIENT_SECRET from secret"
    exit 1
fi

# Authenticate with Port API to get access token
echo "Authenticating with Port API..." >&2
auth_response=$(curl -s -S -w "\n%{http_code}" -X POST "${PORT_API_BASE}/auth/access_token" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\":\"$PORT_CLIENT_ID\",\"clientSecret\":\"$PORT_CLIENT_SECRET\"}" 2>&2)

http_code=$(echo "$auth_response" | tail -n1)
auth_body=$(echo "$auth_response" | sed '$d')

if [[ "$http_code" != "200" ]]; then
    log_error "Authentication failed (HTTP $http_code)"
    log_error "Response: $auth_body"
    exit 1
fi

ACCESS_TOKEN=$(echo "$auth_body" | jq -r '.accessToken // .access_token // empty')

if [[ -z "$ACCESS_TOKEN" ]]; then
    log_error "Failed to extract access token from auth response"
    exit 1
fi

# Query Port API for AWS accounts
echo "Querying Port API for AWS accounts..." >&2

# Fetch all entities (Port API fetches all by default, no pagination params accepted)
url="${PORT_API_BASE}/blueprints/awsAccount/entities"

response=$(curl -s -S -w "\n%{http_code}" -X GET "$url" \
    -H "Authorization: Bearer $ACCESS_TOKEN" 2>&2)

http_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | sed '$d')

if [[ "$http_code" != "200" ]]; then
    log_error "Port API query failed (HTTP $http_code)"
    log_error "Response: $response_body"
    exit 1
fi

# Extract entities from response
all_accounts=$(echo "$response_body" | jq -c '.entities // []')

# Transform to required format: {"account-name": "account-id"}
# Filter for ACTIVE status and use identifier (which contains the actual account ID)
accounts_json=$(echo "$all_accounts" | jq -c '
    map(select(.properties.status == "ACTIVE"))
    | map({
        (.title): .identifier
    })
    | add // {}
')

# Validate output
if ! echo "$accounts_json" | jq -e '.' > /dev/null 2>&1; then
    log_error "Failed to generate valid JSON output"
    exit 1
fi

account_count=$(echo "$accounts_json" | jq 'keys | length')
echo "Successfully retrieved $account_count accounts from Port" >&2

# Output result to stdout
echo "$accounts_json"
