#!/bin/bash
set -e

# Usage: manage-page.sh <create|destroy> <page_identifier> <page_yaml_file> <client_id> <client_secret> [permissions_json] [folder_owner]

ACTION=$1
PAGE_ID=$2
PAGE_YAML=$3
CLIENT_ID=$4
CLIENT_SECRET=$5
PERMISSIONS_JSON=${6:-'{"read":{"roles":["Admin","Member"],"users":[],"teams":[]}}'}
FOLDER_OWNER=${7:-}
FOLDER_ID=$(echo "$FOLDER_OWNER" | tr '[:upper:]' '[:lower:]')
BASE_URL="https://api.us.getport.io"

# Check if python3 is available
if ! command -v python3 &> /dev/null; then
  echo "Error: python3 required for JSON processing" >&2
  exit 1
fi

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
  # Ensure the owner folder exists before placing the page inside it
  if [ -n "$FOLDER_ID" ]; then
    echo "Ensuring folder '${FOLDER_OWNER}' (${FOLDER_ID}) exists..." >&2

    # Try PATCH first (update if exists)
    FOLDER_RESP=$(curl -s -w "\n%{http_code}" -X PATCH "${BASE_URL}/v1/sidebars/catalog/folders/${FOLDER_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"${FOLDER_OWNER}\"}")

    FOLDER_HTTP=$(echo "$FOLDER_RESP" | tail -n1)

    if [ "$FOLDER_HTTP" -ge 200 ] && [ "$FOLDER_HTTP" -lt 300 ]; then
      echo "Folder '${FOLDER_ID}' ready" >&2
    elif [ "$FOLDER_HTTP" -eq 404 ]; then
      # Folder doesn't exist - create it
      FOLDER_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/v1/sidebars/catalog/folders" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"identifier\":\"${FOLDER_ID}\",\"title\":\"${FOLDER_OWNER}\"}")
      FOLDER_HTTP=$(echo "$FOLDER_RESP" | tail -n1)
      if [ "$FOLDER_HTTP" -ge 200 ] && [ "$FOLDER_HTTP" -lt 300 ]; then
        echo "Folder '${FOLDER_ID}' created" >&2
      else
        echo "Warning: Failed to create folder '${FOLDER_ID}'. HTTP ${FOLDER_HTTP}" >&2
        echo "Response: $(echo "$FOLDER_RESP" | sed '$d')" >&2
      fi
    else
      echo "Warning: Failed to upsert folder '${FOLDER_ID}'. HTTP ${FOLDER_HTTP}" >&2
      echo "Response: $(echo "$FOLDER_RESP" | sed '$d')" >&2
    fi
  fi

  echo "Creating/updating page: $PAGE_ID..." >&2

  # Read JSON page definition (Terraform handles YAML->JSON conversion and title capitalization)
  PAGE_JSON=$(python3 -c "
import json, sys
with open('${PAGE_YAML}', 'r') as f:
    data = json.load(f)
print(json.dumps(data))
")

  if [ -z "$PAGE_JSON" ] || [ "$PAGE_JSON" == "null" ]; then
    echo "Failed to convert YAML to JSON" >&2
    exit 1
  fi

  # Delete existing page first (ignore 404), then POST to recreate.
  # Port's WIP widget schema validations treat PUT/PATCH differently from POST,
  # so a clean DELETE + POST is the most reliable upsert strategy.
  DEL_RESP=$(curl -s -w "\n%{http_code}" -X DELETE "${BASE_URL}/v1/pages/${PAGE_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")
  DEL_HTTP=$(echo "$DEL_RESP" | tail -n1)

  if [ "$DEL_HTTP" -ge 200 ] && [ "$DEL_HTTP" -lt 300 ]; then
    echo "Deleted existing page ${PAGE_ID}" >&2
  elif [ "$DEL_HTTP" -eq 404 ]; then
    echo "Page ${PAGE_ID} does not exist yet" >&2
  else
    echo "Warning: DELETE returned HTTP ${DEL_HTTP} (continuing with POST)" >&2
  fi

  # Create the page
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/v1/pages" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAGE_JSON")

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "Page ${PAGE_ID} created successfully" >&2

    # Set page permissions
    echo "Setting page permissions..." >&2
    PERM_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${BASE_URL}/v1/pages/${PAGE_ID}/permissions" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$PERMISSIONS_JSON")

    PERM_HTTP_CODE=$(echo "$PERM_RESPONSE" | tail -n1)

    if [ "$PERM_HTTP_CODE" -ge 200 ] && [ "$PERM_HTTP_CODE" -lt 300 ]; then
      echo "Page permissions set successfully" >&2
    else
      echo "Warning: Failed to set page permissions. HTTP ${PERM_HTTP_CODE}" >&2
      echo "Page is still created but may have default permissions" >&2
    fi

    echo "$BODY"
    exit 0
  else
    echo "Failed to create page. HTTP ${HTTP_CODE}" >&2
    echo "Response: $BODY" >&2
    exit 1
  fi

elif [ "$ACTION" == "destroy" ]; then
  echo "Deleting page: $PAGE_ID..." >&2

  RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${BASE_URL}/v1/pages/${PAGE_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "Page ${PAGE_ID} deleted successfully" >&2
    exit 0
  elif [ "$HTTP_CODE" -eq 404 ]; then
    echo "Page ${PAGE_ID} not found (already deleted)" >&2
    exit 0
  else
    echo "Failed to delete page. HTTP ${HTTP_CODE}" >&2
    echo "Response: $BODY" >&2
    exit 1
  fi

else
  echo "Invalid action: $ACTION. Use 'create' or 'destroy'" >&2
  exit 1
fi
