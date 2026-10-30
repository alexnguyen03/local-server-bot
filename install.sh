#!/usr/bin/env bash
# One-line installer: curl -fsSL https://raw.githubusercontent.com/alexnguyen03/local-server-bot/main/install.sh | sudo bash
# Downloads the latest release tarball (no git clone needed) and hands off to the real installer
# (ops/install.sh) inside it. Safe to run again any number of times.
set -euo pipefail

REPO="${LSB_REPO:-alexnguyen03/local-server-bot}"
DEST="${LSB_SRC:-/devops/_src}"
URL="https://github.com/$REPO/releases/latest/download/local-server-bot.tar.gz"

[ "$(id -u)" = 0 ] || { echo "Must run as root (sudo bash install.sh, or pipe into 'sudo bash')"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v tar  >/dev/null || { echo "tar is required"; exit 1; }

echo ">> Downloading $URL"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/pkg.tar.gz"

echo ">> Extracting to $DEST"
# No rm -rf here: ops/install.conf and ops/structure.json live inside $DEST but are gitignored,
# so they're never part of the tarball — extracting over the directory updates the code without
# touching them. Wiping the directory first would destroy any edits made after the first install.
mkdir -p "$DEST"
tar xzf "$tmp/pkg.tar.gz" -C "$DEST"

echo ">> Running the installer"
exec bash "$DEST/ops/install.sh" "$@"
