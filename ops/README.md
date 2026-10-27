# ops: the bot restarts itself after a problem

LS can be any machine, as long as it's Linux with systemd, has internet, and can reach CS (over VPN or LAN). Two ways to run it:

| Way | When to use it |
|---|---|
| **Plain Linux** (recommended) | A server or PC running Ubuntu/Debian. More stable, no need to keep WSL alive |
| **WSL2 on Windows** | Only have a Windows PC. Needs an extra step from [wsl/](wsl/) |

## Four layers of self-recovery

| Layer | Mechanism |
|---|---|
| Bot crashes or hangs | systemd `Restart=always` (5 seconds). The bot exits itself after 15 minutes without a Telegram connection (`NET_DEAD_SECONDS`) so systemd restarts it |
| Machine reboots | systemd `WantedBy=multi-user.target`: the bot comes up with the machine, no login needed |
| A deploy breaks something | `deploy-core.sh` automatically rolls back to the last good build if `HEALTH_URL` is set and health fails |
| A command is missed while LS is off | The 120-second auto-poll deploys the new build once LS is back up, skipping it if nothing changed |

## Install (plain Linux)

```bash
sudo bash ops/install-service.sh
```

Check it: reboot the machine, type `/ping` in the group. The bot replying `pong` means it's done.

## Install (WSL2)

1. In WSL (root): `bash ops/install-service.sh`. The first run enables systemd and asks for a `wsl --shutdown`, then run it again.
2. In PowerShell (Administrator): `.\ops\wsl\register-wsl-keepalive.ps1` (edit `$distro` if your distro isn't named `Ubuntu`). This task brings WSL up when Windows starts, even before anyone logs in.
3. Check it the same way as above, but reboot Windows without logging in.

## Outside the bot, but still breaks deploys if missing

- **The path to CS**: the VPN must reconnect itself after a reboot (run it as a service, not something that waits for a login). The bot can be alive and still fail every deploy if it can't reach CS.
- **Power**: enable `Restore on AC Power Loss` in the BIOS; disable suspend/hibernate; disable power saving on the network card.
- **OS updates**: schedule reboots outside working hours.
- **WSL2 extra**: disable Windows Sleep and Hibernate, set Active Hours for Windows Update. WSL's network sometimes breaks completely after Windows sleeps or switches networks; `net_watchdog` handles that by restarting the bot.

The bot's `.env` is read by systemd: drop `export` and wrap any value containing `$` in single quotes.
