#!/usr/bin/env bash
# Exercises archivist.sh's state handling in a throwaway git repo:
#   - untracked (external) fragments are copied into the archive's states/
#   - an external fragment replaces a same-named tracked one
#   - external fragments are scrubbed
#   - unselected fragments are filtered out
#   - the same SHA is skipped only while the fingerprint is unchanged
#   - a missing resolved fragment fails the build
#
# Prints a JSON object for Terraform's external data source:
#   {"status": "pass"} or {"status": "fail", "detail": "..."}
# Run directly with: bash archivist/tests/states_test.sh
set -uo pipefail

MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
  local msg=${1//\"/\'}
  printf '{"status":"fail","detail":"%s"}\n' "$msg"
  exit 0
}

# --- Fake platformer repo -----------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/states" "$REPO/archivist/scripts"
cp "$MODULE_DIR/scripts/archivist.sh" "$REPO/archivist/scripts/"
printf 's/SECRET-TOKEN/REDACTED/g\n' > "$REPO/archivist/scrub.sed"
printf 'services:\n  a:\n    from: repo\n' > "$REPO/states/repo-a.yaml"
printf 'services:\n  b:\n    from: repo\n' > "$REPO/states/repo-b.yaml"
printf 'services:\n  shadowed:\n    from: repo\n' > "$REPO/states/shadowed.yaml"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.com add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -qm init

# --- External states dir (user states_paths) ----------------------------
EXT="$WORK/external"
mkdir -p "$EXT"
printf 'services:\n  shadowed:\n    from: external\n' > "$EXT/shadowed.yaml"
printf 'services:\n  ext:\n    token: SECRET-TOKEN\n' > "$EXT/ext-only.yaml"

TAB=$'\t'
STATE_FILES="repo-a${TAB}$REPO/states/repo-a.yaml
shadowed${TAB}$EXT/shadowed.yaml
ext-only${TAB}$EXT/ext-only.yaml"

run_archivist() {
  (cd "$REPO" && ARCHIVIST_STATES="repo-a,shadowed,ext-only" \
    ARCHIVIST_STATE_FILES="$1" ARCHIVIST_FINGERPRINT="$2" \
    bash archivist/scripts/archivist.sh 2>&1)
}

# --- Build ---------------------------------------------------------------
out=$(run_archivist "$STATE_FILES" "fp-1") || fail "first build failed: $out"

OUT_DIR="$REPO/archivist/build"
X="$WORK/extract"
mkdir -p "$X"
tar -xzf "$OUT_DIR/latest.tar.gz" -C "$X" || fail "could not extract archive"

[ -f "$X/states/repo-a.yaml" ] || fail "tracked selected fragment missing"
[ ! -e "$X/states/repo-b.yaml" ] || fail "unselected fragment was not filtered out"
grep -q "from: external" "$X/states/shadowed.yaml" || fail "external fragment did not replace the tracked one"
[ -f "$X/states/ext-only.yaml" ] || fail "external-only fragment missing"
grep -q "REDACTED" "$X/states/ext-only.yaml" || fail "external fragment was not scrubbed"
! grep -q "SECRET-TOKEN" "$X/states/ext-only.yaml" || fail "secret survived the scrub"
grep -q "External states: 2" "$OUT_DIR/MANIFEST.txt" || fail "manifest should count 2 external states"

# --- Idempotency ---------------------------------------------------------
out=$(run_archivist "$STATE_FILES" "fp-1") || fail "second build failed: $out"
echo "$out" | grep -q "skipping" || fail "same SHA + fingerprint should skip"

printf 'services:\n  shadowed:\n    from: external-v2\n' > "$EXT/shadowed.yaml"
out=$(run_archivist "$STATE_FILES" "fp-2") || fail "rebuild failed: $out"
echo "$out" | grep -q "skipping" && fail "changed fingerprint should rebuild"
tar -xzf "$OUT_DIR/latest.tar.gz" -C "$X" ./states/shadowed.yaml || fail "could not extract rebuilt archive"
grep -q "from: external-v2" "$X/states/shadowed.yaml" || fail "rebuild did not pick up the changed external fragment"

# --- Missing fragment ----------------------------------------------------
if run_archivist "ghost${TAB}$EXT/ghost.yaml" "fp-3" >/dev/null; then
  fail "missing resolved fragment should fail the build"
fi

printf '{"status":"pass"}\n'
