#!/bin/bash
# compose-stack.sh - converge a Docker Compose stack from a git repository.
#
# Run by the `compose` application type (applications module) through an SSM
# State Manager association, every 30 minutes and on every change. It is
# idempotent: a run with nothing new only re-applies the firewall and runs
# `docker compose up -d`, which recreates nothing that is already right.
#
#   up    install docker + the compose plugin if missing, check out the repo
#         at STACK_REF, write the .env, open STACK_PORTS in the host firewall,
#         install a systemd unit (so the stack comes back after a reboot), and
#         bring the stack up (rebuilding images when the commit or .env changed)
#   down  stop and remove the stack's containers (named volumes are kept),
#         close its ports, remove its unit and checkout
#
# Inputs (environment):
#   APP_ACTION        up (default) | down
#   APP_ENV_FILE      file whose contents become the project's .env
#   STACK_NAME        stack name: compose project, unit and lock names
#   STACK_REPOSITORY  git URL (public, or reachable without credentials)
#   STACK_REF         branch, tag or commit (default HEAD: the remote's default branch)
#   STACK_PATH        compose project directory inside the repo (default .)
#   STACK_DIRECTORY   checkout location (default /opt/stacks/$STACK_NAME)
#   STACK_PORTS       space-separated host firewall openings: 443/tcp 51000-51999/udp
#
# Ports published by Docker (`ports:` in compose) bypass the INPUT chain, so
# STACK_PORTS is for services on the host's network (network_mode: host).
# Cloud-provider firewalls (security lists, security groups) are not touched.
#
# Overrides, for tests: STACK_STATE_DIR, STACK_UNIT_DIR, STACK_LIB_DIR,
# STACK_LOCK_DIR, STACK_SKIP_PACKAGES=1.
#
# The installed copy of this script also serves the unit:
#   compose-stack.sh firewall <name>   re-apply the stack's firewall rules
#   compose-stack.sh unfirewall <name> remove them

set -euo pipefail

STATE_ROOT="${STACK_STATE_DIR:-/var/lib/stacks}"
UNIT_DIR="${STACK_UNIT_DIR:-/etc/systemd/system}"
LIB_DIR="${STACK_LIB_DIR:-/usr/local/lib/stacks}"
LOCK_DIR="${STACK_LOCK_DIR:-/run/lock}"

log() { echo "[stack${STACK_NAME:+:$STACK_NAME}] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Firewall: rules are runtime-only and tagged with the stack's name. The unit
# re-applies them before every start, so they survive reboots without saving
# the whole ruleset (which would also capture Docker's own chains).
# ---------------------------------------------------------------------------

firewall_backend() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo ufw
  elif command -v iptables >/dev/null 2>&1; then
    echo iptables
  else
    echo none
  fi
}

# Remove every rule this stack added. iptables rules are found by their
# comment; firewalld and ufw by the ports recorded at the last apply.
firewall_close() {
  local name=$1 backend applied="$STATE_ROOT/$1/ports.applied" spec proto range
  backend=$(firewall_backend)
  case "$backend" in
    iptables)
      for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        { "$cmd" -S INPUT 2>/dev/null || true; } | { grep -F -- "--comment stack:$name " || true; } |
          sed 's/^-A /-D /' | while read -r -a rule; do "$cmd" "${rule[@]}" || true; done
      done
      ;;
    firewalld | ufw)
      [ -f "$applied" ] || return 0
      while read -r spec; do
        [ -n "$spec" ] || continue
        range=${spec%/*} proto=${spec#*/}
        if [ "$backend" = firewalld ]; then
          firewall-cmd --remove-port="$range/$proto" >/dev/null 2>&1 || true
        else
          ufw delete allow "${range/-/:}/$proto" >/dev/null 2>&1 || true
        fi
      done <"$applied"
      ;;
  esac
  rm -f "$applied"
}

firewall_open() {
  local name=$1 wanted="$STATE_ROOT/$1/ports" backend spec proto range
  firewall_close "$name"
  [ -s "$wanted" ] || return 0
  backend=$(firewall_backend)
  [ "$backend" != none ] || { log "no firewall tool found; ports left as they are"; return 0; }
  while read -r spec; do
    [ -n "$spec" ] || continue
    range=${spec%/*} proto=${spec#*/}
    case "$backend" in
      iptables)
        # Inserted at the top of INPUT, ahead of any catch-all REJECT
        # (Oracle Cloud's Ubuntu images end INPUT with one).
        for cmd in iptables ip6tables; do
          command -v "$cmd" >/dev/null 2>&1 || continue
          "$cmd" -I INPUT 1 -p "$proto" -m "$proto" --dport "${range/-/:}" \
            -m comment --comment "stack:$name" -j ACCEPT
        done
        ;;
      firewalld) firewall-cmd --add-port="$range/$proto" >/dev/null ;;
      ufw) ufw allow "${range/-/:}/$proto" >/dev/null ;;
    esac
  done <"$wanted"
  cp "$wanted" "$STATE_ROOT/$name/ports.applied"
  log "firewall ($backend): opened $(tr '\n' ' ' <"$wanted")"
}

# Unit entry points: `compose-stack.sh firewall|unfirewall <name>`
case "${1:-}" in
  firewall) firewall_open "${2:?stack name}"; exit 0 ;;
  unfirewall) firewall_close "${2:?stack name}"; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Packages: docker engine + compose plugin, from Docker's repositories.
# Upgrades are left to patch management (the repos stay configured).
# ---------------------------------------------------------------------------

ensure_packages() {
  local id like
  # shellcheck disable=SC1091
  . /etc/os-release
  id=${ID:-} like=" ${ID_LIKE:-} "

  if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log "installing git and curl"
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update -q
      DEBIAN_FRONTEND=noninteractive apt-get install -yq git curl ca-certificates
    else
      dnf install -y git curl ca-certificates
    fi
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi

  log "installing docker engine and the compose plugin ($id)"
  case "$id" in
    ubuntu | debian)
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$id/gpg" -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$id ${VERSION_CODENAME:-$UBUNTU_CODENAME} stable" \
        >/etc/apt/sources.list.d/docker.list
      DEBIAN_FRONTEND=noninteractive apt-get update -q
      DEBIAN_FRONTEND=noninteractive apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    amzn)
      # Amazon Linux ships docker but no compose or buildx packages.
      local arch plugins=/usr/libexec/docker/cli-plugins
      dnf install -y docker
      arch=$(uname -m)
      mkdir -p "$plugins"
      curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" -o "$plugins/docker-compose"
      local buildx
      buildx=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
      curl -fsSL "https://github.com/docker/buildx/releases/download/$buildx/buildx-$buildx.linux-${arch/x86_64/amd64}" -o "$plugins/docker-buildx"
      chmod 0755 "$plugins/docker-compose" "$plugins/docker-buildx"
      ;;
    *)
      local repo
      case "$id$like" in
        fedora*) repo=fedora ;;
        rhel* | ol* | *" rhel "*) repo=rhel ;;
        *" centos "* | *" fedora "*) repo=centos ;;
        *) die "unsupported distribution: $id" ;;
      esac
      dnf install -y dnf-plugins-core
      dnf config-manager --add-repo "https://download.docker.com/linux/$repo/docker-ce.repo"
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
  esac
  systemctl enable --now docker
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

: "${STACK_NAME:?STACK_NAME is required}"
[[ "$STACK_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "STACK_NAME must be lowercase letters, digits, - and _"
ACTION="${APP_ACTION:-up}"
DIRECTORY="${STACK_DIRECTORY:-/opt/stacks/$STACK_NAME}"
PROJECT_DIR="$DIRECTORY/${STACK_PATH:-.}"
STATE="$STATE_ROOT/$STACK_NAME"
UNIT="stack-$STACK_NAME.service"

case "$DIRECTORY" in
  /*/*) ;;
  *) die "STACK_DIRECTORY must be an absolute path at least two levels deep (got '$DIRECTORY')" ;;
esac

mkdir -p "$STATE" "$LOCK_DIR"
exec 9>"$LOCK_DIR/stack-$STACK_NAME.lock"
flock -w 3600 9 || die "another run holds the lock"

compose() { docker compose --project-directory "$PROJECT_DIR" --project-name "$STACK_NAME" "$@"; }

stack_down() {
  if [ -f "$UNIT_DIR/$UNIT" ]; then
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$UNIT"
    systemctl daemon-reload
  fi
  if [ -d "$PROJECT_DIR" ] && command -v docker >/dev/null 2>&1; then
    # Name every profile, or profiled services would be left running.
    local args=() profile
    while read -r profile; do
      [ -n "$profile" ] && args+=(--profile "$profile")
    done < <(compose config --profiles 2>/dev/null || true)
    compose "${args[@]}" down --remove-orphans
  elif command -v docker >/dev/null 2>&1; then
    # No checkout left: compose finds the containers by project label.
    docker compose --project-name "$STACK_NAME" down --remove-orphans || true
  fi
  firewall_close "$STACK_NAME"
  # Only remove a checkout this script made.
  if [ -f "$STATE/managed" ] && [ -d "$DIRECTORY/.git" ]; then
    rm -rf "$DIRECTORY"
  fi
  rm -rf "$STATE"
  log "down: containers removed, named volumes kept"
}

checkout() {
  local ref="${STACK_REF:-HEAD}"
  : "${STACK_REPOSITORY:?STACK_REPOSITORY is required}"
  if [ ! -d "$DIRECTORY/.git" ]; then
    [ ! -e "$DIRECTORY" ] || [ -z "$(ls -A "$DIRECTORY")" ] || die "$DIRECTORY exists and is not a git checkout"
    mkdir -p "$DIRECTORY"
    git -C "$DIRECTORY" init -q
    git -C "$DIRECTORY" remote add origin "$STACK_REPOSITORY"
    touch "$STATE/managed"
  fi
  git -C "$DIRECTORY" remote set-url origin "$STACK_REPOSITORY"
  GIT_TERMINAL_PROMPT=0 git -C "$DIRECTORY" fetch -q --depth 1 origin "$ref"
  git -C "$DIRECTORY" checkout -q --force --detach FETCH_HEAD
  git -C "$DIRECTORY" rev-parse HEAD
}

stack_up() {
  local before after env_before="" env_after docker_bin
  [ "${STACK_SKIP_PACKAGES:-0}" = 1 ] || ensure_packages

  before=$(git -C "$DIRECTORY" rev-parse HEAD 2>/dev/null || true)
  after=$(checkout)
  [ -d "$PROJECT_DIR" ] || die "STACK_PATH '${STACK_PATH:-.}' is not a directory in the repository"
  [ "$before" = "$after" ] || log "checked out ${STACK_REF:-HEAD} at $after (was ${before:-nothing})"

  # The environment file becomes the project's .env: compose reads it for
  # interpolation, and COMPOSE_PROFILES / COMPOSE_FILE in it pick what runs.
  [ ! -f "$PROJECT_DIR/.env" ] || env_before=$(sha256sum <"$PROJECT_DIR/.env")
  if [ -n "${APP_ENV_FILE:-}" ]; then
    install -m 0600 "$APP_ENV_FILE" "$PROJECT_DIR/.env"
  else
    : >"$PROJECT_DIR/.env"
  fi
  env_after=$(sha256sum <"$PROJECT_DIR/.env")

  # Firewall: record what is wanted, apply it now and on every unit start.
  printf '%s\n' ${STACK_PORTS:-} >"$STATE/ports"
  sed -i '/^$/d' "$STATE/ports"
  while read -r spec; do
    [[ "$spec" =~ ^[0-9]+(-[0-9]+)?/(tcp|udp)$ ]] || die "bad port '$spec' (want 443/tcp or 51000-51999/udp)"
  done <"$STATE/ports"
  mkdir -p "$LIB_DIR"
  install -m 0755 "$0" "$LIB_DIR/compose-stack.sh"
  firewall_open "$STACK_NAME"

  # The unit starts the stack at boot (after docker) and re-applies the
  # firewall first. Containers keep their own restart policies.
  docker_bin=$(command -v docker)
  local unit_tmp
  unit_tmp=$(mktemp)
  cat >"$unit_tmp" <<EOF
# Managed by platformer (compose-stack.sh). Changes are overwritten.
[Unit]
Description=Compose stack $STACK_NAME
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStartPre=$LIB_DIR/compose-stack.sh firewall $STACK_NAME
ExecStart=$docker_bin compose --project-name $STACK_NAME up -d --remove-orphans
ExecStop=$docker_bin compose --project-name $STACK_NAME stop
ExecStopPost=$LIB_DIR/compose-stack.sh unfirewall $STACK_NAME
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  if ! cmp -s "$unit_tmp" "$UNIT_DIR/$UNIT" 2>/dev/null; then
    install -m 0644 "$unit_tmp" "$UNIT_DIR/$UNIT"
    systemctl daemon-reload
    log "installed $UNIT"
  fi
  rm -f "$unit_tmp"
  systemctl enable "$UNIT" >/dev/null 2>&1

  # Bring it up. Rebuild only when the source or the environment changed;
  # otherwise `up -d` is a cheap self-heal (it recreates what went missing).
  if [ "$before" != "$after" ] || [ "$env_before" != "$env_after" ]; then
    log "source or environment changed: building and recreating"
    compose up -d --build --remove-orphans
  else
    compose up -d --remove-orphans
  fi
  # Mark the unit active without restarting anything (its ExecStart is the
  # same `up -d`); `systemctl start` is a no-op when it already is.
  systemctl start "$UNIT"
  compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
}

case "$ACTION" in
  up) stack_up ;;
  down) stack_down ;;
  *) die "APP_ACTION must be up or down (got '$ACTION')" ;;
esac
