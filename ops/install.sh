#!/usr/bin/env bash
# Upsert: first install or update the deploy scripts and bot on LS (Linux or WSL2). Run as root.
# Safe to run again any number of times. Never overwrites existing config/secrets
# (ops/install.conf, ops/structure.json, bot/.env, uat/.secrets, service.env).
# bot.allow and each service's folder tree are regenerated every run from ops/structure.json (not hand-edited).
# Exit code 10: just enabled systemd for WSL, needs 'wsl --shutdown' then a retry.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../src" && pwd)"
EX="$(cd "$HERE/../examples" && pwd)"

# Create install.conf from the sample if it doesn't exist yet (upsert, no real path ever in git).
[ -f "$HERE/install.conf" ] || sed 's/\r$//' "$HERE/install.conf.example" > "$HERE/install.conf"
. "$HERE/install.conf"
D="${DEVOPS_ROOT:-/devops}"

[ "$(id -u)" = 0 ] || { echo "Must run as root (sudo bash ops/install.sh)"; exit 1; }

echo ">> [1/6] System tools"
missing=0
for c in git skopeo jq python3; do command -v "$c" >/dev/null || missing=1; done
python3 -c 'import venv, ensurepip' 2>/dev/null || missing=1
if [ "$missing" = 1 ]; then
  apt-get update -qq
  apt-get install -y git skopeo jq python3 python3-venv ca-certificates
fi
echo "   (JDK 21 for Jib and docker.io for Dockerfile builds: install only when a service needs it, see docs/OPERATIONS.md)"

echo ">> [2/6] Deploy scripts -> $D/bin"
mkdir -p "$D/bin" "$D/bot" "$D/uat"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for f in build-local deploy deploy-bot deploy-core.sh resolve-tag.sh lsb; do
  sed 's/\r$//' "$SRC/bin/$f" > "$tmp"
  bash -n "$tmp" || { echo "!! Syntax error: $f"; exit 1; }
  install -m 755 "$tmp" "$D/bin/$f"
done
ln -sf "$D/bin/lsb" /usr/local/bin/lsb 2>/dev/null || echo "   (couldn't symlink lsb into /usr/local/bin, run it as $D/bin/lsb instead)"

echo ">> [3/6] Bot -> $D/bot"
sed 's/\r$//' "$SRC/bot/bot.py" > "$D/bot/bot.py"
[ -d "$D/bot/.venv" ] || python3 -m venv "$D/bot/.venv"
"$D/bot/.venv/bin/pip" install -q --upgrade python-telegram-bot

echo ">> [4/6] Services: add a service? just add a block to ops/structure.json and re-run this step"
# Create structure.json from the sample if missing (upsert). If it exists, leave it alone.
[ -f "$HERE/structure.json" ] || sed 's/\r$//' "$HERE/structure.json.example" > "$HERE/structure.json"
jq empty "$HERE/structure.json" || { echo "!! ops/structure.json is not valid JSON"; exit 1; }
jq -e '[.services[] | (.env and .project)] | all' "$HERE/structure.json" >/dev/null \
  || { echo "!! Every service in ops/structure.json needs env and project"; exit 1; }
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
    chmod 644 "$dir/service.env"
    created_env="$created_env\n  $dir/service.env"
  fi
done < "$D/bot.allow"
[ -z "$created_env" ] || echo -e "!! Created new service.env file(s); fill in the required fields then run again (see docs/OPERATIONS.md):$created_env"

echo ">> [5/6] Configuration"
if [ ! -f "$D/bot/.env" ]; then
  sed 's/\r$//' "$EX/bot.env.example" > "$D/bot/.env"
  chmod 600 "$D/bot/.env"
  echo "!! Created $D/bot/.env from the sample. Fill in BOT_TOKEN, ALLOWED_CHAT_ID, ALLOWED_USER_IDS, then run this again."
  echo "   For the other files (common.env, .secrets, service.env) see examples/ and docs/OPERATIONS.md."
  exit 0
fi
grep -q '^DEVOPS_ROOT=' "$D/bot/.env" || echo "DEVOPS_ROOT=$D" >> "$D/bot/.env"   # upsert: add if missing, leave other lines alone

echo ">> [6/6] Bot service"
rc=0; DEVOPS_ROOT="$D" bash "$HERE/install-service.sh" || rc=$?
[ "$rc" = 0 ] || exit "$rc"
systemctl restart deploy-bot
echo ">> Done. Type /ping in the Telegram group to check."
