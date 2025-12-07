#!/bin/bash
set -e

# Manages auto-generated blueprint catalog pages: renames them with
# namespace-scoped titles and sets page permissions.
#
# Port auto-creates a catalog page per blueprint with generic titles
# ("Artifacts", "Event Bus") and org-wide visibility. This script
# discovers those pages by blueprint identifier, renames them
# (e.g. "Zapdos' Artifacts"), and restricts read access to the team.
#
# Usage: manage-catalog-page-permissions.sh <config_file> <client_id> <client_secret> <permissions_json>
#   config_file: Path to JSON file mapping blueprint identifiers to desired page titles
#     e.g. {"artifact-ns":"Ns' Artifacts","eventBus-ns":"Ns' Events"}

CONFIG_FILE=$1
CLIENT_ID=$2
CLIENT_SECRET=$3
PERMISSIONS_JSON=${4:-'{"read":{"roles":["Admin"],"teams":[]}}'}
BASE_URL="https://api.us.getport.io"

if [ -z "$CONFIG_FILE" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "Usage: $0 <config_file> <client_id> <client_secret> [permissions_json]" >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

CATALOG_PAGES_JSON=$(cat "$CONFIG_FILE")

# Authenticate
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

# List all pages
echo "Fetching pages..." >&2
PAGES_RESPONSE=$(curl -s -X GET "${BASE_URL}/v1/pages" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")

# Iterate over each blueprint -> title mapping
echo "$CATALOG_PAGES_JSON" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | while IFS=$'\t' read -r BP_ID DESIRED_TITLE; do
  # Find the auto-generated catalog page for this blueprint
  PAGE_ID=$(echo "$PAGES_RESPONSE" | jq -r --arg bp "$BP_ID" '
    .pages[]
    | select(.type == "blueprint-entities" and .blueprint == $bp)
    | .identifier
  ' 2>/dev/null | head -1)

  if [ -z "$PAGE_ID" ] || [ "$PAGE_ID" == "null" ]; then
    echo "Warning: No catalog page found for blueprint '${BP_ID}', skipping" >&2
    continue
  fi

  # Rename the page (use jq to build payload safely - handles apostrophes in titles)
  echo "Renaming page '${PAGE_ID}' -> '${DESIRED_TITLE}'..." >&2
  RENAME_PAYLOAD=$(jq -n --arg title "$DESIRED_TITLE" '{title: $title}')
  RENAME_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${BASE_URL}/v1/pages/${PAGE_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$RENAME_PAYLOAD")

  RENAME_HTTP=$(echo "$RENAME_RESPONSE" | tail -n1)

  if [ "$RENAME_HTTP" -ge 200 ] && [ "$RENAME_HTTP" -lt 300 ]; then
    echo "Renamed '${PAGE_ID}'" >&2
  else
    echo "Warning: Failed to rename '${PAGE_ID}'. HTTP ${RENAME_HTTP}" >&2
    echo "Response: $(echo "$RENAME_RESPONSE" | sed '$d')" >&2
  fi

  # Set page permissions
  echo "Setting permissions on '${PAGE_ID}'..." >&2
  PERM_RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${BASE_URL}/v1/pages/${PAGE_ID}/permissions" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PERMISSIONS_JSON")

  PERM_HTTP=$(echo "$PERM_RESPONSE" | tail -n1)

  if [ "$PERM_HTTP" -ge 200 ] && [ "$PERM_HTTP" -lt 300 ]; then
    echo "Permissions set on '${PAGE_ID}'" >&2
  else
    echo "Warning: Failed to set permissions on '${PAGE_ID}'. HTTP ${PERM_HTTP}" >&2
    echo "Response: $(echo "$PERM_RESPONSE" | sed '$d')" >&2
  fi
done

echo "Done" >&2
