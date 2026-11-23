#!/bin/bash
# Integration test for applications/scripts/compose-stack.sh.
#
# Runs the real script against a throwaway git repository with real git and
# docker, and fakes for the host-level tools (systemctl, iptables, ip6tables,
# ufw, firewall-cmd) so nothing on this machine changes but a few containers,
# which are removed again. No root needed.
#
#   bash applications/scripts/tests/test-compose-stack.sh

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/compose-stack.sh"
ROOT=$(mktemp -d)
NAME="cstest-$$"
PASS=0
FAIL=0

cleanup() {
  docker compose --project-name "$NAME" --profile extra down --remove-orphans --volumes >/dev/null 2>&1 || true
  docker volume rm "${NAME}_data" >/dev/null 2>&1 || true
  docker image rm "$NAME-app" >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- fakes ------------------------------------------------------------------
FAKES="$ROOT/fakes"
mkdir -p "$FAKES"
export FAKE_LOG="$ROOT/calls.log" FAKE_FW="$ROOT/fw"
mkdir -p "$FAKE_FW"

cat >"$FAKES/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$FAKE_LOG"
EOF

# iptables emulation: keeps INPUT rules in a file, in `iptables -S` form.
cat >"$FAKES/iptables" <<'EOF'
#!/bin/bash
f="$FAKE_FW/$(basename "$0").rules"; touch "$f"
echo "$(basename "$0") $*" >>"$FAKE_LOG"
op=$1 chain=$2; shift 2
case "$op" in
  -S) grep -- "^-A $chain " "$f" || true ;;
  -I) shift; { echo "-A $chain $*"; cat "$f"; } >"$f.new"; mv "$f.new" "$f" ;;
  -D) grep -vxF -- "-A $chain $*" "$f" >"$f.new" || true; mv "$f.new" "$f" ;;
esac
EOF
cp "$FAKES/iptables" "$FAKES/ip6tables"

cat >"$FAKES/ufw" <<'EOF'
#!/bin/bash
echo "Status: inactive"
EOF
cat >"$FAKES/firewall-cmd" <<'EOF'
#!/bin/bash
exit 252
EOF
chmod +x "$FAKES"/*

# --- a stack repository -------------------------------------------------------
REPO="$ROOT/repo"
mkdir -p "$REPO/deploy"
cat >"$REPO/deploy/compose.yaml" <<'EOF'
services:
  app:
    build: .
    image: ${IMAGE_NAME}
    command: [sh, -c, "sleep 3600"]
    environment:
      GREETING: ${GREETING:-none}
    volumes:
      - data:/data
  extra:
    image: docker.io/library/busybox:1.36
    profiles: [extra]
    command: [sleep, "3600"]
volumes:
  data:
EOF
echo 'FROM docker.io/library/busybox:1.36' >"$REPO/deploy/Dockerfile"
echo '.env' >"$REPO/.gitignore"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm one

ENVFILE="$ROOT/app.env"
run() {
  PATH="$FAKES:$PATH" \
    APP_ACTION="${ACTION:-up}" APP_ENV_FILE="$ENVFILE" \
    STACK_NAME="${TEST_NAME:-$NAME}" STACK_REPOSITORY="$REPO" STACK_REF=main STACK_PATH=deploy \
    STACK_DIRECTORY="${TEST_DIR:-$ROOT/opt/stacks/$NAME}" STACK_PORTS="${PORTS:-}" \
    STACK_STATE_DIR="$ROOT/state" STACK_UNIT_DIR="$ROOT/units" STACK_LIB_DIR="$ROOT/lib" \
    STACK_LOCK_DIR="$ROOT/lock" STACK_SKIP_PACKAGES=1 \
    bash "$SCRIPT"
}
mkdir -p "$ROOT/units"
CHECKOUT="$ROOT/opt/stacks/$NAME"
app_id() { docker compose --project-name "$NAME" ps -q app; }
fw_rules() { grep -c -- "--comment stack:$NAME " "$FAKE_FW/iptables.rules" 2>/dev/null || true; }

echo "compose-stack.sh integration test ($NAME)"

# --- first deploy ----------------------------------------------------------------
printf "IMAGE_NAME='%s'\nGREETING='hello'\nCOMPOSE_PROFILES='extra'\n" "$NAME-app" >"$ENVFILE"
PORTS="51000-51001/udp 8443/tcp" run >"$ROOT/out1" 2>&1 || { cat "$ROOT/out1"; bad "first up exits 0"; exit 1; }
check "first up builds" "grep -q 'source or environment changed' '$ROOT/out1'"
check "app container running" "[ -n \"\$(app_id)\" ]"
check "profiled service running (COMPOSE_PROFILES from .env)" "[ -n \"\$(docker compose --project-name '$NAME' ps -q extra)\" ]"
check ".env installed from APP_ENV_FILE" "cmp -s '$ENVFILE' '$CHECKOUT/deploy/.env'"
check ".env is private" "[ \"\$(stat -c %a '$CHECKOUT/deploy/.env')\" = 600 ]"
check "environment reaches the container" "docker inspect \"\$(app_id)\" --format '{{.Config.Env}}' | grep -q GREETING=hello"
check "firewall: one rule per port, tagged" "[ \"\$(fw_rules)\" = 2 ]"
check "firewall: ip6tables too" "[ \"\$(grep -c 'stack:$NAME ' '$FAKE_FW/ip6tables.rules')\" = 2 ]"
check "firewall: range uses iptables syntax" "grep -q -- '--dport 51000:51001' '$FAKE_FW/iptables.rules'"
check "unit installed" "[ -f '$ROOT/units/stack-$NAME.service' ]"
check "unit re-applies the firewall before start" "grep -q 'ExecStartPre=$ROOT/lib/compose-stack.sh firewall $NAME' '$ROOT/units/stack-$NAME.service'"
check "unit starts the stack in the project dir" "grep -q 'WorkingDirectory=$CHECKOUT/deploy' '$ROOT/units/stack-$NAME.service'"
check "unit enabled and started" "grep -q 'systemctl enable stack-$NAME.service' '$FAKE_LOG' && grep -q 'systemctl start stack-$NAME.service' '$FAKE_LOG'"
check "script installed for the unit" "[ -x '$ROOT/lib/compose-stack.sh' ]"

# --- converge with nothing new ------------------------------------------------------
ID1=$(app_id)
: >"$FAKE_LOG"
PORTS="51000-51001/udp 8443/tcp" run >"$ROOT/out2" 2>&1 || { cat "$ROOT/out2"; bad "second up exits 0"; }
check "no-op run does not rebuild" "! grep -q 'source or environment changed' '$ROOT/out2'"
check "no-op run keeps the container" "[ \"\$(app_id)\" = '$ID1' ]"
check "no-op run leaves the unit alone" "! grep -q daemon-reload '$FAKE_LOG'"
check "no-op run does not duplicate firewall rules" "[ \"\$(fw_rules)\" = 2 ]"

# --- environment change ---------------------------------------------------------------
sed -i "s/hello/bye/" "$ENVFILE"
PORTS="51000-51001/udp" run >"$ROOT/out3" 2>&1 || { cat "$ROOT/out3"; bad "env change up exits 0"; }
check "environment change rebuilds" "grep -q 'source or environment changed' '$ROOT/out3'"
check "environment change recreates the container" "docker inspect \"\$(app_id)\" --format '{{.Config.Env}}' | grep -q GREETING=bye"
check "removed port is closed" "[ \"\$(fw_rules)\" = 1 ] && ! grep -q 8443 '$FAKE_FW/iptables.rules'"

# --- new commit -------------------------------------------------------------------------
echo "# two" >>"$REPO/deploy/Dockerfile"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qam two
PORTS="51000-51001/udp" run >"$ROOT/out4" 2>&1 || { cat "$ROOT/out4"; bad "new commit up exits 0"; }
check "new commit is checked out" "[ \"\$(git -C '$CHECKOUT' rev-parse HEAD)\" = \"\$(git -C '$REPO' rev-parse HEAD)\" ]"
check "new commit rebuilds" "grep -q 'checked out main' '$ROOT/out4' && grep -q 'source or environment changed' '$ROOT/out4'"
check "untracked .env survives the checkout" "grep -q bye '$CHECKOUT/deploy/.env'"

# --- unit entry points ------------------------------------------------------------------------
PATH="$FAKES:$PATH" STACK_STATE_DIR="$ROOT/state" bash "$ROOT/lib/compose-stack.sh" unfirewall "$NAME"
check "unfirewall removes the rules" "[ \"\$(fw_rules)\" = 0 ]"
PATH="$FAKES:$PATH" STACK_STATE_DIR="$ROOT/state" bash "$ROOT/lib/compose-stack.sh" firewall "$NAME" >/dev/null
check "firewall re-applies them" "[ \"\$(fw_rules)\" = 1 ]"

# --- bad input ----------------------------------------------------------------------------------
check "bad port spec fails" "! PORTS='51000:51001' run >/dev/null 2>&1"
check "bad stack name fails" "! TEST_NAME='Bad Name' run >/dev/null 2>&1"
mkdir -p "$ROOT/occupied" && touch "$ROOT/occupied/file"
check "refuses a non-empty, non-git directory" "! TEST_DIR='$ROOT/occupied' run >/dev/null 2>&1 && [ -f '$ROOT/occupied/file' ]"

# --- teardown ------------------------------------------------------------------------------------
: >"$FAKE_LOG"
ACTION=down run >"$ROOT/out5" 2>&1 || { cat "$ROOT/out5"; bad "down exits 0"; }
check "down removes all containers, profiled ones too" "[ -z \"\$(docker compose --project-name '$NAME' --profile extra ps -aq)\" ]"
check "down keeps named volumes" "docker volume inspect '${NAME}_data' >/dev/null 2>&1"
check "down closes the firewall" "[ \"\$(fw_rules)\" = 0 ]"
check "down disables and removes the unit" "grep -q 'systemctl disable --now stack-$NAME.service' '$FAKE_LOG' && [ ! -f '$ROOT/units/stack-$NAME.service' ]"
check "down removes the checkout and state" "[ ! -e '$CHECKOUT' ] && [ ! -e '$ROOT/state/$NAME' ]"
ACTION=down run >/dev/null 2>&1
check "down is idempotent" "[ \$? -eq 0 ]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
