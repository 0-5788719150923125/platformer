#!/usr/bin/env bash
# Generate deployment matrix summary for PR comments
# Usage: ./generate-matrix-summary.sh <matrix-json>
# Example: ./generate-matrix-summary.sh '[]'
# Output: Markdown-formatted summary with blast radius metrics

set -euo pipefail

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# Input: matrix JSON (required), commit metadata (optional, via env)
# COMMIT_TITLE and COMMIT_SHA are set by the workflow  -  avoids shell escaping issues
MATRIX_JSON="${1:-}"
COMMIT_TITLE="${COMMIT_TITLE:-}"
COMMIT_SHA="${COMMIT_SHA:-}"

if [[ -z "$MATRIX_JSON" ]]; then
    echo "Error: Matrix JSON required as first argument" >&2
    echo "Usage: $0 '<matrix-json>'" >&2
    exit 1
fi

# Validate JSON
if ! echo "$MATRIX_JSON" | jq -e '.' > /dev/null 2>&1; then
    echo "Error: Invalid JSON provided" >&2
    exit 1
fi

# Calculate metrics
ACCOUNTS=$(echo "$MATRIX_JSON" | jq -r '[.[].account_name] | unique | length')
REGIONS=$(echo "$MATRIX_JSON" | jq -r '[.[].region] | unique | length')
TOTAL=$(echo "$MATRIX_JSON" | jq '. | length')

# Get account and region names for display
ACCOUNT_NAMES=$(echo "$MATRIX_JSON" | jq -r '[.[].account_name] | unique | join(", ")')
REGION_NAMES=$(echo "$MATRIX_JSON" | jq -r '[.[].region] | unique | sort | join(", ")')

# Build optional commit line
COMMIT_LINE=""
if [[ -n "$COMMIT_TITLE" ]]; then
    SHORT_SHA="${COMMIT_SHA:+\`${COMMIT_SHA:0:7}\` }"
    COMMIT_LINE="**Commit**: (${SHORT_SHA}) ${COMMIT_TITLE}

"
fi

# Generate markdown summary
cat <<EOF
<!-- terraform-matrix-summary -->
## 🫵 Platformer

Managing **${TOTAL} total deployment(s)** across **${ACCOUNTS} account(s)** and **${REGIONS} region(s)**.

**Accounts**: \`${ACCOUNT_NAMES}\`

**Regions**: \`${REGION_NAMES}\`

${COMMIT_LINE}
---

<details>
<summary>🤖 JSON</summary>

\`\`\`json
${MATRIX_JSON}
\`\`\`
</details>

*This comment will update automatically when you push new commits.*
EOF
