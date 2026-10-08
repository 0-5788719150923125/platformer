#!/usr/bin/env bash
# Run `terraform apply` while recording the terminal, then render the session to
# static/apply.webp (the animation at the top of README.md).
#
#   scripts/apply.sh [terraform apply args...]
#
# Behaves like a normal apply (prompts, colors, exit code). The image is only
# replaced when the apply succeeds and actually changes something.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cmd="terraform apply"
for arg in "$@"; do
  cmd+=" $(printf '%q' "$arg")"
done

# Pin the pty to the renderer's grid so Terraform wraps for that width.
script -q -e -T "$tmp/timing" -O "$tmp/log" -c "stty cols 120 rows 36 2>/dev/null; $cmd"
status=$?

if [ "$status" -eq 0 ] \
  && grep -q "Apply complete!" "$tmp/log" \
  && ! grep -q "Resources: 0 added, 0 changed, 0 destroyed" "$tmp/log"; then
  python3 "$root/scripts/render_apply_webp.py" \
    --log "$tmp/log" --timing "$tmp/timing" --command "$cmd" \
    --out "$root/static/apply.webp" \
    || echo "apply.sh: rendering static/apply.webp failed (apply itself succeeded)" >&2
fi

exit "$status"
