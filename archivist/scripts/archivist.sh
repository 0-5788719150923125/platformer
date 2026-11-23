#!/usr/bin/env bash
# Archivist - Scrubbed Platformer Archive Generator
#
# Produces a sanitized, versioned tarball of the platformer codebase.
# Steps:
#   1. git archive (respects .gitignore and .gitattributes export-ignore)
#   2. Add untracked resolved fragments (user states_paths), then filter
#      states/ to only resolved state fragments
#   3. Apply scrub.sed - replace sensitive strings with generic placeholders
#   4. Rewrite local module sources to pinned git refs (github.com)
#   5. Repack, update symlink, write manifest
#
# Output: archivist/build/platformer-<date>-<sha>.tar.gz
#
# Usage: bash archivist/scripts/archivist.sh
# Or invoked automatically by the archivist Terraform module.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODULE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)   # archivist/
REPO_ROOT=$(git rev-parse --show-toplevel)
SCRUB_SED="$MODULE_DIR/scrub.sed"
OUTPUT_DIR="$MODULE_DIR/build"

# Public repo URL for rewritten module sources.
# Sub-path format: git::<url>//<subdir>?ref=<sha>
# Terraform resolves the ref against the remote, so SHA must be reachable.
GITHUB_BASE="git::https://github.com/acme-sandbox/platformer"

GIT_SHA=$(git rev-parse --short HEAD)
GIT_SHA_FULL=$(git rev-parse HEAD)
DATE=$(git log -1 --format=%cd --date=format:%Y-%m-%d HEAD)
ARCHIVE_NAME="platformer-${DATE}-${GIT_SHA}.tar.gz"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
LATEST_PATH="$OUTPUT_DIR/latest.tar.gz"
FINGERPRINT_PATH="$OUTPUT_DIR/.fingerprint"
FINGERPRINT="${ARCHIVIST_FINGERPRINT:-}"

# Skip rebuild if this SHA is already current and nothing outside the commit
# changed (resolved states, external fragment content, scrub rules).
if [ -L "$LATEST_PATH" ] && [ "$(readlink "$LATEST_PATH")" = "$ARCHIVE_NAME" ] \
  && [ "$(cat "$FINGERPRINT_PATH" 2>/dev/null)" = "$FINGERPRINT" ]; then
  echo "archivist: archive for ${GIT_SHA} already exists, skipping"
  exit 0
fi

echo "archivist: building ${ARCHIVE_NAME}"

mkdir -p "$OUTPUT_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Step 1: git archive - respects .gitignore and .gitattributes export-ignore rules
# scrub.sed is export-ignored so it is not included in the archive
git -C "$REPO_ROOT" archive --format=tar HEAD | tar -xf - -C "$TMP_DIR"

# Step 2a: Add resolved fragments that git doesn't track
# ARCHIVIST_STATE_FILES has one "name<TAB>path" line per resolved fragment.
# Tracked files are already in the archive at their committed version. Anything
# else (user states_paths outside the repo, or gitignored dirs inside it) is
# copied to states/<name>.yaml, replacing a same-named repo fragment - the same
# precedence the config module used. Step 3 scrubs these like everything else.
EXTERNAL_STATES=0
if [ -n "${ARCHIVIST_STATE_FILES:-}" ]; then
  mkdir -p "$TMP_DIR/states"
  while IFS=$'\t' read -r state_name state_path; do
    [ -n "$state_name" ] || continue
    if [ ! -f "$state_path" ]; then
      echo "archivist: resolved fragment not found: $state_path" >&2
      exit 1
    fi
    if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$state_path" >/dev/null 2>&1; then
      continue
    fi
    cp "$state_path" "$TMP_DIR/states/${state_name}.yaml"
    EXTERNAL_STATES=$((EXTERNAL_STATES + 1))
  done <<< "$ARCHIVIST_STATE_FILES"
  echo "archivist: added ${EXTERNAL_STATES} fragment(s) from outside git"
fi

# Step 2b: Filter states/ to only resolved state fragments
# ARCHIVIST_STATES is a comma-separated list set by Terraform (e.g., "praxis-cpu-test,praxis-imaging").
# Any states/*.yaml not in the list is removed from the archive.
if [ -n "${ARCHIVIST_STATES:-}" ] && [ -d "$TMP_DIR/states" ]; then
  IFS=',' read -ra KEEP_STATES <<< "$ARCHIVIST_STATES"
  for state_file in "$TMP_DIR"/states/*.yaml; do
    [ -f "$state_file" ] || continue
    state_name=$(basename "$state_file" .yaml)
    keep=false
    for s in "${KEEP_STATES[@]}"; do
      if [ "$s" = "$state_name" ]; then
        keep=true
        break
      fi
    done
    if [ "$keep" = false ]; then
      rm "$state_file"
    fi
  done
  echo "archivist: filtered states/ to ${#KEEP_STATES[@]} resolved fragment(s)"
fi

# Step 3: Apply scrub rules to all text files
find "$TMP_DIR" \( \
  -name "*.tf"   -o -name "*.yaml" -o -name "*.yml"  -o \
  -name "*.sh"   -o -name "*.md"   -o -name "*.json" -o \
  -name "*.hcl"  -o -name "*.j2" \
\) | while IFS= read -r file; do
  sed -i -f "$SCRUB_SED" "$file"
done

# Step 4: Rewrite local module sources to pinned git refs
# Terraform supports git sources in the form:
#   git::<url>//<subdir>?ref=<sha>
# Two patterns cover all usages in this codebase:
#   source = "./module"   (root main.tf - references sibling module dirs)
#   source = "../module"  (sub-module files - e.g. portal, compute -> preflight)
find "$TMP_DIR" -name "*.tf" | while IFS= read -r file; do
  # Root-level: ./module -> git ref
  sed -i "s|source = \"\./\([^\"]*\)\"|source = \"${GITHUB_BASE}//\1?ref=${GIT_SHA_FULL}\"|g" "$file"
  # Sub-module: ../module -> git ref
  sed -i "s|source = \"\.\./\([^\"]*\)\"|source = \"${GITHUB_BASE}//\1?ref=${GIT_SHA_FULL}\"|g" "$file"
done

# Step 5: Repack
tar -czf "$ARCHIVE_PATH" -C "$TMP_DIR" .

# Step 6: Atomic symlink update
ln -sf "$ARCHIVE_NAME" "$LATEST_PATH"
printf '%s' "$FINGERPRINT" > "$FINGERPRINT_PATH"

# Step 7: Write manifest
FILE_COUNT=$(find "$TMP_DIR" -type f | wc -l | tr -d ' ')
SCRUB_RULES=$(grep -c "^s/" "$SCRUB_SED" 2>/dev/null || echo "0")
cat > "$OUTPUT_DIR/MANIFEST.txt" <<EOF
Archive:       $ARCHIVE_NAME
Git SHA:       $GIT_SHA_FULL
Date:          $DATE
Files:         $FILE_COUNT
Scrub rules:   $SCRUB_RULES
External states: $EXTERNAL_STATES
Module source: ${GITHUB_BASE}?ref=${GIT_SHA_FULL}
Built by:      archivist/scripts/archivist.sh
EOF

echo "archivist: complete -> $ARCHIVE_PATH"
