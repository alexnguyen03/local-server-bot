#!/usr/bin/env bash
# Install and enable the bot service (systemd). Run as root on LS: plain Linux or WSL2.
# Stop any manually running bot first (Ctrl+C): two bots polling the same token get a 409 Conflict.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  # Plain Linux always has systemd; missing systemd only happens on WSL2 before it's enabled.
  if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "This machine isn't running systemd (PID 1 isn't systemd). systemd is required to install the service."; exit 1
  fi
  if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    echo "wsl.conf already has a [boot] section, add systemd=true to it yourself:"; cat /etc/wsl.conf; exit 1
  fi
  printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf
  echo ">> Enabled systemd for WSL. From PowerShell: wsl --shutdown, reopen WSL, then run 'lsb start' again."
  exit 10
fi

D="${DEVOPS_ROOT:-/devops}"
sed "s|@DEVOPS_ROOT@|$D|g" "$HERE/deploy-bot.service" > /etc/systemd/system/deploy-bot.service
chmod 644 /etc/systemd/system/deploy-bot.service
systemctl daemon-reload
systemctl enable --now deploy-bot
sleep 3
systemctl --no-pager status deploy-bot | head -8
echo "Log: journalctl -u deploy-bot -f    Restart: systemctl restart deploy-bot"
