#!/usr/bin/env bash
# ops/install.sh <install|init|start|stop>   (default: install)
#   install  system tools + deploy scripts + bot code/venv. No config, no service running yet.
#   init     generate ops/structure.json, bot.allow, each service's service.env stub, bot/.env stub
#            from the samples. Run again any time you add a service to ops/structure.json.
#   start    start/enable the systemd service. Needs bot/.env (and each service.env) filled in first.
#   stop     stop the systemd service.
# Every subcommand is an upsert: safe to run any number of times, never overwrites existing
# config/secrets (ops/install.conf, ops/structure.json, bot/.env, uat/.secrets, service.env).
# Exit code 10 from 'start': just enabled systemd for WSL, run 'wsl --shutdown' then 'start' again.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../src" && pwd)"
EX="$(cd "$HERE/../examples" && pwd)"

# Create install.conf from the sample if it doesn't exist yet (upsert, no real path ever in git).
[ -f "$HERE/install.conf" ] || sed 's/\r$//' "$HERE/install.conf.example" > "$HERE/install.conf"
# Always world-writable: this runs as root, but it's meant to be hand-edited from Windows/a GUI
# too (e.g. through \\wsl.localhost\...), which can't write a root-only file. Not a secret.
chmod 666 "$HERE/install.conf" 2>/dev/null || true
. "$HERE/install.conf"
D="${DEVOPS_ROOT:-/devops}"
cmd="${1:-install}"

[ "$(id -u)" = 0 ] || { echo "Must run as root (sudo bash ops/install.sh $cmd)"; exit 1; }

do_install() {
  echo ">> [1/3] System tools"
  missing=0
  for c in git skopeo jq python3; do command -v "$c" >/dev/null || missing=1; done
  python3 -c 'import venv, ensurepip' 2>/dev/null || missing=1
  if [ "$missing" = 1 ]; then
    apt-get update -qq
    apt-get install -y git skopeo jq python3 python3-venv ca-certificates
  fi
  echo "   (JDK 21 for Jib and docker.io for Dockerfile builds: install only when a service needs it, see docs/OPERATIONS.md)"

  echo ">> [2/3] Deploy scripts -> $D/bin"
  mkdir -p "$D/bin" "$D/bot" "$D/uat"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  for f in build-local deploy deploy-bot deploy-core.sh resolve-tag.sh lsb; do
    sed 's/\r$//' "$SRC/bin/$f" > "$tmp"
    bash -n "$tmp" || { echo "!! Syntax error: $f"; exit 1; }
    install -m 755 "$tmp" "$D/bin/$f"
  done
  ln -sf "$D/bin/lsb" /usr/local/bin/lsb 2>/dev/null || echo "   (couldn't symlink lsb into /usr/local/bin, run it as $D/bin/lsb instead)"

  echo ">> [3/3] Bot -> $D/bot"
  sed 's/\r$//' "$SRC/bot/bot.py" > "$D/bot/bot.py"
  [ -d "$D/bot/.venv" ] || python3 -m venv "$D/bot/.venv"
  "$D/bot/.venv/bin/pip" install -q --upgrade python-telegram-bot

  echo ">> Install done. Next: lsb init   (or: bash $HERE/install.sh init)"
}

do_init() {
  echo ">> Services: add a block to ops/structure.json, then run 'init' again to pick it up"
  # Create structure.json from the sample if missing (upsert). If it exists, leave it alone.
  [ -f "$HERE/structure.json" ] || sed 's/\r$//' "$HERE/structure.json.example" > "$HERE/structure.json"
  jq empty "$HERE/structure.json" || { echo "!! ops/structure.json is not valid JSON"; exit 1; }
  jq -e '[.services[] | (.env and .project)] | all' "$HERE/structure.json" >/dev/null \
    || { echo "!! Every service in ops/structure.json needs env and project"; exit 1; }
  # Always world-writable, same reasoning as install.conf above: hand-edited from Windows/a GUI too.
  chmod 666 "$HERE/structure.json" 2>/dev/null || true
  cp "$HERE/structure.json" "$D/structure.json"
  # bot.allow and each service's folder tree are derived from structure.json -> regenerate every run, not hand-edited.
  jq -r '.services[] | "\(.env)/\(.project)"' "$HERE/structure.json" > "$D/bot.allow"
  created_env=""
  while IFS=/ read -r env project; do
    dir="$D/$env/$project"
    mkdir -p "$dir"
    if [ ! -f "$dir/service.env" ]; then
      cat > "$dir/service.env" <<'EOT'
# ---- required: fill these in, then run /doctor_<env> (or "deploy-bot doctor") to check again ----
GH_REPO=CHANGEME          # <owner>/<image-repo> on GitHub, e.g. myorg/myservice
APP=CHANGEME              # image name on the CS registry
DOCKHAND_STACK=CHANGEME   # stack name in Dockhand

# ---- optional: leave empty/removed = use the default ----
HEALTH_URL=                       # empty = skip the health check
TRACK_TAG=latest                  # tag to track when using GHCR (the default BUILD_MODE)
COMPOSE_REPO=                     # empty = needs a local compose.yaml in this same folder
COMPOSE_PATH=docker-compose.yml
COMPOSE_REF=main

# ---- only needed when building on LS, not via GHCR ----
#BUILD_MODE=local
#BUILD_BRANCH=main
#BUILD_TYPE=docker        # docker | jib
EOT
      created_env="$created_env\n  $dir/service.env"
    fi
    # Every run, not just on creation: fixes files made world-writable only after this line existed,
    # and keeps it editable from Windows/a GUI through \\wsl.localhost\... (writes as a non-root user).
    # No secret lives in service.env.
    chmod 666 "$dir/service.env" 2>/dev/null || true
  done < "$D/bot.allow"
  [ -z "$created_env" ] || echo -e "!! Created new service.env file(s); fill in the required fields:$created_env"

  echo ">> Bot config"
  if [ ! -f "$D/bot/.env" ]; then
    sed 's/\r$//' "$EX/bot.env.example" > "$D/bot/.env"
    echo "!! Created $D/bot/.env from the sample. Fill in BOT_TOKEN, ALLOWED_CHAT_ID, ALLOWED_USER_IDS."
    echo "   For the other files (common.env, .secrets) see examples/ and docs/OPERATIONS.md."
  fi
  # Editable from Windows/a GUI like structure.json/service.env above. Unlike those, this one holds
  # a real secret (BOT_TOKEN) -- widening it means anyone with filesystem access to this machine can
  # read it. Fine for a single-admin LS; tighten back to 600 by hand if that's not your setup.
  chmod 666 "$D/bot/.env" 2>/dev/null || true
  grep -q '^DEVOPS_ROOT=' "$D/bot/.env" || echo "DEVOPS_ROOT=$D" >> "$D/bot/.env"   # upsert: add if missing, leave other lines alone

  echo ">> Init done. Fill in the service.env/.env files above, then run: lsb start"
}

do_start() {
  [ -f "$D/bot/.env" ] || { echo "!! $D/bot/.env not found, run 'lsb init' first"; exit 1; }
  grep -q '^BOT_TOKEN=.' "$D/bot/.env" || echo "   (warning: BOT_TOKEN looks empty in $D/bot/.env — the bot won't be able to log in)"
  DEVOPS_ROOT="$D" bash "$HERE/install-service.sh"
  systemctl restart deploy-bot
  echo ">> Started. Type /ping in the Telegram group to check."
}

do_stop() {
  systemctl stop deploy-bot
  echo ">> Stopped. (it will start again on the next reboot unless you also run: systemctl disable deploy-bot)"
}

case "$cmd" in
  install) do_install ;;
  init)    do_init ;;
  start)   do_start ;;
  stop)    do_stop ;;
  *) echo "Usage: $0 <install|init|start|stop>" >&2; exit 64 ;;
esac
