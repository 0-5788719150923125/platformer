#!/usr/bin/env bash
# build-lambdas.sh - Copy shared modules into each bot's Lambda directory
# before Terraform's archive_file packages them. Called by a null_resource
# provisioner with source hash trigger.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAMBDAS_DIR="$SCRIPT_DIR/../lambdas"
SHARED_DIR="$LAMBDAS_DIR/shared"

if [ ! -d "$SHARED_DIR" ]; then
    echo "ERROR: shared directory not found at $SHARED_DIR" >&2
    exit 1
fi

# Copy shared/ into each bot directory (except shared itself and kb-ingestion-reporter)
for bot_dir in "$LAMBDAS_DIR"/*/; do
    bot_name="$(basename "$bot_dir")"
    [ "$bot_name" = "shared" ] && continue
    [ "$bot_name" = "kb-ingestion-reporter" ] && continue

    target="$bot_dir/ai_backend.py"
    cp "$SHARED_DIR/ai_backend.py" "$target"
    echo "Copied ai_backend.py -> $bot_name/"
done
