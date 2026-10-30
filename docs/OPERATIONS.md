# Operations

## Install or update on LS

```bash
sudo bash ops/install.sh        # Linux
install.cmd                     # Windows, runs it inside WSL
```

Safe to run again any number of times (upsert): code is always overwritten with the latest version, but config and secrets you've already filled in (`ops/structure.json`, `bot/.env`, `common.env`, `.secrets`, `service.env`) are never touched. See [../README.md](../README.md#quickstart) for the full first-run flow.

## Restarting itself after a crash or reboot

See [../ops/README.md](../ops/README.md): the systemd service (plain Linux or WSL2), and the conditions outside the bot's control that still matter (VPN, power, OS updates).

## Tools required on LS

```bash
apt install -y git skopeo jq python3-pip
apt install -y openjdk-21-jdk     # only needed if a service builds with jib (Quarkus/Gradle)
apt install -y docker.io          # only needed if a service builds with docker (Dockerfile), needs systemd
pip install python-telegram-bot --break-system-packages
```

(`ops/install.sh` installs `git`, `skopeo`, `jq`, `python3` automatically; the two `apt install` lines above are only needed when a service actually uses that build type.)

## Adding a new service

1. Add a block to `ops/structure.json` (see [../ops/structure.json.example](../ops/structure.json.example)).
2. Run `install.cmd`/`sudo bash ops/install.sh` again: it creates the folder, generates `bot.allow`, and the bot automatically gets the new job.
3. Fill in the `service.env` stub it just created there (see the warning install.sh prints, or [examples/](../examples)).
4. Run `install.cmd`/`install.sh` again, then try `/doctor_<env>` in Telegram or `deploy-bot "deploy uat <project> dry"` in a terminal.

## Letting a coworker issue commands

Have them type `/id` in the group to get their `user_id`. Add it to `ALLOWED_USER_IDS` in the bot's env, then `systemctl restart deploy-bot`. You can see who ran what from the `RECV`/`DENY` lines in `bot.log`.

## Switching a service between the two flows

- To flow local: add `BUILD_MODE=local`, `BUILD_BRANCH`, `BUILD_TYPE` (+ `BUILD_DIR` if the repo is a monorepo) to `service.env`; make sure `GH_COMPOSE_TOKEN` is set in `.secrets`.
- Back to flow GHCR: remove the `BUILD_MODE` line.

## Troubleshooting

| Symptom | Check |
|---|---|
| Bot is silent | `systemctl status deploy-bot`; `tail -f /devops/bot/bot.log`; is LS asleep or offline |
| Bot reports `NET` | LS's network is flaky; the watchdog restarts the bot itself after 15 minutes |
| Command sits there, never runs | Queued behind another deploy (`flock`); look for the "waiting for a turn" line |
| Build failed (code 20) | The `!!` and `|` lines in Telegram; `/devops/uat/.../build.log` |
| Jib `RegistryCredentialsNotSentException` | The `sendCredentialsOverHttp` flag must be present in `build-local` (both the `-D` and `JAVA_TOOL_OPTIONS` forms) |
| Code 22 | This commit just failed to build; fix the code and push, or force a retry with `/redeploy_<x>_uat` |
| Code 21 | A required tool is missing (git, skopeo, JDK 21, docker) |
| Stack stuck `created`, no container | A required stack variable is missing in Dockhand, or the compose file has `pull_policy: never` |
| "OK" but nothing's running | `HEALTH_URL` is empty; check directly in Dockhand |
| Restoring a previous build | `/auto_off`, `deploy uat <x> sha-xxxxxxx` (the tag must be one of the 2 builds still on CS), then `/auto_on` |
| CS registry disk full | Enable `REGISTRY_STORAGE_DELETE_ENABLED=true`, run `registry garbage-collect` |

## When LS is off

Containers on CS keep running. Manual restore: open Dockhand (`DOCKHAND_URL` in `common.env`), set the stack's image tag back to the previous build (still on CS), and redeploy. New builds can't be deployed until LS is back up.

## After LS reboots

The bot sends "Bot online" to the group within about a minute. If it doesn't show up, check `systemctl status deploy-bot`. If LS is WSL2, also check the Scheduled Task that starts WSL (see [../ops/README.md](../ops/README.md)).
