#!/bin/bash
set -e

# Usage: manage-action.sh <create|destroy> <action_json_file> <env_file> [permissions_json]
#
# env_file should contain:
#   PORT_CLIENT_ID=...
#   PORT_CLIENT_SECRET=...

ACTION=$1
ACTION_JSON=$2
ENV_FILE=$3
PERMISSIONS_JSON=$4
BASE_URL="https://api.us.getport.io"

# Convert relative paths to absolute
if [ -n "$ACTION_JSON" ] && [[ ! "$ACTION_JSON" = /* ]]; then
  ACTION_JSON="$(cd "$(dirname "$ACTION_JSON")" && pwd)/$(basename "$ACTION_JSON")"
fi
if [ -n "$ENV_FILE" ] && [[ ! "$ENV_FILE" = /* ]]; then
  ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
fi

# Source credentials from env file
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: Environment file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

CLIENT_ID="$PORT_CLIENT_ID"
CLIENT_SECRET="$PORT_CLIENT_SECRET"

# Authenticate and get access token
echo "Authenticating to Port API..." >&2
TOKEN_RESPONSE=$(curl -s -X POST "${BASE_URL}/v1/auth/access_token" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"${CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.accessToken')

if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
  echo "Failed to authenticate to Port API" >&2
  echo "Response: $TOKEN_RESPONSE" >&2
  exit 1
fi

if [ "$ACTION" == "create" ]; then
  # Extract action identifier from JSON
  ACTION_ID=$(jq -r '.identifier' "$ACTION_JSON")

  echo "Creating/updating action: $ACTION_ID..." >&2

  # Read action definition
  ACTION_PAYLOAD=$(cat "$ACTION_JSON")

  # Try to create action first (POST)
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/v1/actions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$ACTION_PAYLOAD")

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  # If action exists (409), update it instead (PUT)
  if [ "$HTTP_CODE" -eq 409 ]; then
    echo "Action exists, updating..." >&2
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${BASE_URL}/v1/actions/${ACTION_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$ACTION_PAYLOAD")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
  fi

  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "Action ${ACTION_ID} created/updated successfully" >&2

    # Set action permissions if provided
    if [ -n "$PERMISSIONS_JSON" ]; then
      echo "Setting action permissions..." >&2
      PERM_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${BASE_URL}/v1/actions/${ACTION_ID}/permissions" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PERMISSIONS_JSON")

      PERM_HTTP_CODE=$(echo "$PERM_RESPONSE" | tail -n1)

      if [ "$PERM_HTTP_CODE" -ge 200 ] && [ "$PERM_HTTP_CODE" -lt 300 ]; then
        echo "Action permissions set successfully" >&2
      else
        echo "Warning: Failed to set action permissions. HTTP ${PERM_HTTP_CODE}" >&2
      fi
    fi

    echo "$BODY"
    exit 0
  else
    echo "Failed to create/update action. HTTP ${HTTP_CODE}" >&2
    echo "Response: $BODY" >&2
    exit 1
  fi

elif [ "$ACTION" == "destroy" ]; then
  # Extract action identifier from JSON
  ACTION_ID=$(jq -r '.identifier' "$ACTION_JSON")

  echo "Deleting action: $ACTION_ID..." >&2

  RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${BASE_URL}/v1/actions/${ACTION_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "Action ${ACTION_ID} deleted successfully" >&2
    exit 0
  elif [ "$HTTP_CODE" -eq 404 ]; then
    echo "Action ${ACTION_ID} not found (already deleted)" >&2
    exit 0
  else
    echo "Failed to delete action. HTTP ${HTTP_CODE}" >&2
    echo "Response: $BODY" >&2
    exit 1
  fi

else
  echo "Invalid action: $ACTION. Use 'create' or 'destroy'" >&2
  exit 1
fi
