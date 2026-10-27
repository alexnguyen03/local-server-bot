#!/usr/bin/env python3
"""Telegram job bot: receives commands from a group, runs fixed scripts, logs everything.

Environment variables (set in .env):
    BOT_TOKEN         required
    ALLOWED_CHAT_ID   id of the group allowed to issue commands (leave empty at first, use /id to get it)
    ALLOWED_USER_IDS  comma-separated list of user ids (leave empty at first)
"""
import asyncio
import json
import logging
import os
import signal
import socket
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

from telegram import BotCommand, Update
from telegram.error import NetworkError, TimedOut
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

BASE_DIR = Path(__file__).resolve().parent

# --------------------------------------------------------------- logging ----
fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
root = logging.getLogger()
root.setLevel(logging.INFO)

console = logging.StreamHandler()
console.setFormatter(fmt)
root.addHandler(console)

file_handler = RotatingFileHandler(
    BASE_DIR / "bot.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8"
)
file_handler.setFormatter(fmt)
root.addHandler(file_handler)

# the http library is very noisy, and its URLs contain the token -> keep only WARNING and above
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

log = logging.getLogger("bot")

# ---------------------------------------------------------------- config ----
TOKEN = os.environ.get("BOT_TOKEN")
if not TOKEN:
    raise SystemExit("Missing BOT_TOKEN (load it from .env: set -a; source .env; set +a)")

ALLOWED_CHAT = int(os.environ["ALLOWED_CHAT_ID"]) if os.environ.get("ALLOWED_CHAT_ID") else None
ALLOWED_USERS = {
    int(x) for x in os.environ.get("ALLOWED_USER_IDS", "").split(",") if x.strip()
}
# CI bot (CI_BOT_IDS): its id (the number before ':' in its token). May only run deploy_*/redeploy_*/ping
# inside ALLOWED_CHAT itself, no other command.
# OPEN_READONLY=1: EVERYONE in ALLOWED_CHAT may use read-only commands (ping, status_<env>). Not deploy.
OPEN_READONLY = os.environ.get("OPEN_READONLY", "") == "1"
CI_BOT_IDS = {
    int(x) for x in os.environ.get("CI_BOT_IDS", "").split(",") if x.strip()
}

# command -> fixed script. The user can NEVER pass in a path or an argument.
# Telegram command names may only contain a-z, 0-9, underscore (NO hyphens).
# deploy-bot takes ONE fixed string, checks its own syntax, and only deploys an entry listed in <DEVOPS_ROOT>/bot.allow.
DEVOPS_ROOT = os.environ.get("DEVOPS_ROOT", "/devops")
DEPLOY_BOT = f"{DEVOPS_ROOT}/bin/deploy-bot"


def deploy_job(text: str, desc: str, timeout: int = 1800) -> dict:
    return {"cwd": DEVOPS_ROOT, "cmd": [DEPLOY_BOT, text], "timeout": timeout, "desc": desc}


# ----------------------------------------------------- services (structure.json) ----
# The single source of truth for the env/project/service tree is <DEVOPS_ROOT>/structure.json, generated
# from ops/structure.json by ops/install.sh. To add a service: add a block to ops/structure.json then
# re-run install.cmd/install.sh — do NOT hand-edit JOBS/TREE/bot.allow.
try:
    SERVICES = json.loads((Path(DEVOPS_ROOT) / "structure.json").read_text(encoding="utf-8"))["services"]
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    log.warning("Could not read %s/structure.json (run ops/install.sh to create it) — no services yet", DEVOPS_ROOT)
    SERVICES = []
# skip any block missing env/project/name instead of crashing the whole bot over one hand-edit mistake
SERVICES = [s for s in SERVICES if isinstance(s, dict) and s.get("env") and s.get("project") and s.get("name")]

JOBS = {"ping": {"cwd": "/", "cmd": ["echo", "pong"], "timeout": 10, "desc": "Check the bot is alive"}}
READONLY_JOBS = {"ping"}
tree_lines = [DEVOPS_ROOT]
for env in dict.fromkeys(s["env"] for s in SERVICES):   # distinct, keep first-seen order
    JOBS[f"status_{env}"] = deploy_job(f"status {env}", f"{env.upper()}: show the running build of each service", 60)
    READONLY_JOBS.add(f"status_{env}")
    # doctor is not readonly (not for OPEN_READONLY/the CI bot): it prints optional values too, not for everyone to see.
    JOBS[f"doctor_{env}"] = deploy_job(f"doctor {env}", f"{env.upper()}: check what's missing and what's set in service.env", 60)
    tree_lines.append(f"└─ {env}   /status_{env}  /doctor_{env}")
    for s in (x for x in SERVICES if x["env"] == env):
        key, base = s["name"].replace("-", "_"), f"deploy {env} {s['name']}"
        JOBS[f"deploy_{key}_{env}"] = deploy_job(base, f"{env.upper()}: deploy {s['name']} (skipped if unchanged)")
        JOBS[f"redeploy_{key}_{env}"] = deploy_job(f"{base} force", f"{env.upper()}: FORCE redeploy {s['name']} even if unchanged")
        line = f"   {s['project']}/{s['name']}   /deploy_{key}_{env}  /redeploy_{key}_{env} (force)"
        if s.get("dry"):
            JOBS[f"dry_{key}_{env}"] = deploy_job(f"{base} dry", f"{env.upper()}: dry run {s['name']} (no deploy)", 300)
            line += f"  /dry_{key}_{env} (dry run)"
        tree_lines.append(line)
tree_lines += ["", "deploy: skipped when unchanged. redeploy: force it anyway.",
               "/auto_status  /auto_on  /auto_off   auto-deploy when a new image shows up", "/ping  /id  /help"]
TREE = "\n".join(tree_lines)   # shown on /help

# when a deploy is skipped because nothing changed, the bot suggests the matching force command
FORCE_HINT = {n: n.replace("deploy_", "redeploy_", 1) for n in JOBS if n.startswith("deploy_")}
# deploy-bot stops itself at 1500s; the bot's own timeout (1800s) is just a safety net behind that.

THREAD = int(os.environ["ALLOWED_THREAD_ID"]) if os.environ.get("ALLOWED_THREAD_ID") else None  # topic (if any)

# Auto-deploy: every AUTO_INTERVAL seconds the bot runs 'deploy' for every service with "auto": true in structure.json.
# deploy skips itself automatically when the image and compose are unchanged, so it only really deploys once CI
# pushes a new image to GHCR. AUTO_DEPLOY in .env (comma-separated job names) overrides this list, for turning
# something on/off quickly without re-running install.
AUTO_INTERVAL = int(os.environ.get("AUTO_INTERVAL", "120"))
MAX_AUTO_CHARS = 1500
MAX_OUTPUT_CHARS = 3000    # number of characters of output sent back to the group

locks: dict[str, asyncio.Lock] = {name: asyncio.Lock() for name in JOBS}


def who(update: Update) -> str:
    u, c = update.effective_user, update.effective_chat
    uname = f"@{u.username}" if u and u.username else (u.full_name if u else "?")
    kind = " BOT" if u is not None and getattr(u, "is_bot", False) else ""
    return f"user={u.id if u else '?'} ({uname}){kind} chat={c.id if c else '?'} [{c.type if c else '?'}]"


def ci_may_run(name: str) -> bool:
    return name == "ping" or name.startswith(("deploy_", "redeploy_"))


def authorized(update: Update, name: str | None = None) -> bool:
    """Users on the list may run any command. The CI bot may only run a deploy job (name passed in)."""
    u, c = update.effective_user, update.effective_chat
    if ALLOWED_CHAT is None or u is None or c is None:
        return False
    if c.type == "private":                 # a DM to the bot: only users on the list
        return u.id in ALLOWED_USERS
    if c.id != ALLOWED_CHAT:
        return False
    if u.id in ALLOWED_USERS:
        return True
    if OPEN_READONLY and name in READONLY_JOBS:
        return True
    return name is not None and u.id in CI_BOT_IDS and ci_may_run(name)


# -------------------------------------------------------------- handlers ----
async def log_incoming(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """Runs before every other handler (group=-1): logs every incoming message."""
    msg = update.effective_message
    if msg is None:
        return
    text = (msg.text or msg.caption or f"<{msg.effective_attachment.__class__.__name__ if msg.effective_attachment else 'non-text'}>")
    log.info("RECV  %s thread=%s text=%r", who(update), msg.message_thread_id, text[:200])


async def cmd_id(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    thread = update.message.message_thread_id
    await update.message.reply_text(
        f"chat_id: {update.effective_chat.id}\nuser_id: {update.effective_user.id}\n"
        f"thread_id: {thread if thread else '(none: the group has no topics, or this is the General topic)'}"
    )
    log.info("DONE  /id returned chat_id/user_id to %s", who(update))


async def cmd_help(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        log.warning("DENY  /help denied: %s", who(update))
        return
    await update.message.reply_text(TREE)
    log.info("DONE  /help for %s", who(update))


async def run_job(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """The user typed /<command>."""
    name = update.message.text.split()[0].lstrip("/").split("@")[0]
    await _run(update, name)


async def _run(update: Update, name: str) -> None:
    msg = update.effective_message
    job = JOBS.get(name)
    if not job:
        return
    cmd, cwd, timeout = job["cmd"], job["cwd"], job.get("timeout", 600)

    if not authorized(update, name):
        log.warning("DENY  /%s denied: %s", name, who(update))
        return  # stay silent, reveal nothing to a stranger

    lock = locks[name]
    if lock.locked():
        log.info("BUSY  /%s already running, ignoring the request from %s", name, who(update))
        await msg.reply_text(f"{name} is already running, wait for it to finish then try again.")
        return

    async with lock:
        log.info("START /%s -> %s (cwd=%s, by %s)", name, " ".join(cmd), cwd, who(update))
        await msg.reply_text(f"Running {name}...")
        t0 = time.monotonic()
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=cwd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                start_new_session=True,   # so the whole process tree can be killed, not just the first process
            )
        except FileNotFoundError:
            missing = cwd if not os.path.isdir(cwd) else cmd[0]
            log.error("FAIL  /%s: %s not found", name, missing)
            await msg.reply_text(f"{name} failed: {missing} not found")
            return
        except PermissionError:
            log.error("FAIL  /%s: no permission to enter %s or run %s", name, cwd, cmd[0])
            await msg.reply_text(f"{name} failed: permission denied.")
            return

        # Read output line by line: log it as it arrives, and report progress to the chat every 60s
        lines: list[str] = []

        async def pump() -> None:
            assert proc.stdout is not None
            async for raw in proc.stdout:
                line = raw.decode(errors="replace").rstrip("\n")
                lines.append(line)
                log.info("OUT   [%s] %s", name, line)

        async def heartbeat() -> None:
            while True:
                await asyncio.sleep(60)
                last = lines[-1] if lines else "(no output yet)"
                log.info("WAIT  /%s has run for %.0fs, last line: %s", name, time.monotonic() - t0, last)
                try:
                    await msg.reply_text(f"{name} is still running ({time.monotonic() - t0:.0f}s)\n> {last[:300]}")
                except Exception as e:  # a failed progress message must not break the job
                    log.warning("WAIT  could not send progress: %s", e)

        hb = asyncio.create_task(heartbeat())
        try:
            await asyncio.wait_for(asyncio.gather(pump(), proc.wait()), timeout=timeout)
        except asyncio.TimeoutError:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            await proc.wait()
            log.error("FAIL  /%s exceeded %ss, stopped", name, timeout)
            await msg.reply_text(f"{name} exceeded {timeout}s, stopped.")
            return
        finally:
            hb.cancel()

        dur = time.monotonic() - t0
        text = "\n".join(lines)
        level = logging.INFO if proc.returncode == 0 else logging.ERROR
        log.log(level, "END   /%s exit=%s in %.1fs, output %d chars",
                name, proc.returncode, dur, len(text))

        hint = ""
        if proc.returncode == 0 and "use --force" in text and name in FORCE_HINT:
            hint = f"\n\nNothing changed. To run it anyway: /{FORCE_HINT[name]}"
        await msg.reply_text(
            f"{name} finished (exit {proc.returncode}, {dur:.1f}s)\n"
            f"{text[-MAX_OUTPUT_CHARS:] or '(no output)'}{hint}"
        )
        log.info("DONE  /%s sent the result back to the chat", name)


# ------------------------------------------------------------- auto deploy ----
_default_auto = ",".join(f"deploy_{s['name'].replace('-', '_')}_{s['env']}" for s in SERVICES if s.get("auto"))
AUTO_JOBS = [
    j for j in (x.strip() for x in os.environ.get("AUTO_DEPLOY", _default_auto).split(","))
    if j
]
for _j in [j for j in AUTO_JOBS if not (j.startswith("deploy_") and j in JOBS)]:
    log.warning("AUTO_DEPLOY: skipping '%s' (not a deploy_* job present in JOBS)", _j)
AUTO_JOBS = [j for j in AUTO_JOBS if j.startswith("deploy_") and j in JOBS]
auto_enabled = True
auto_state = {j: {"fails": 0, "sig": None, "notified": False, "next": 0.0} for j in AUTO_JOBS}


async def notify(app: Application, text: str) -> None:
    if ALLOWED_CHAT is None:
        return
    try:
        await app.bot.send_message(ALLOWED_CHAT, text, message_thread_id=THREAD)
    except Exception:
        log.exception("Could not send a notification to the chat")


async def capture(job: dict) -> tuple[int, str]:
    """Run a job, return (exit code, output). Kills the whole process tree on timeout."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *job["cmd"], cwd=job["cwd"],
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            start_new_session=True,
        )
    except (FileNotFoundError, PermissionError) as e:
        return 127, f"could not run: {e}"
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=job.get("timeout", 600))
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        await proc.wait()
        return 124, f"exceeded {job.get('timeout', 600)}s, stopped"
    return proc.returncode, out.decode(errors="replace")


async def auto_tick(app: Application, name: str) -> None:
    lock = locks[name]
    st = auto_state[name]
    if lock.locked() or time.monotonic() < st["next"]:   # a manual deploy is running, or we're backing off after a failure
        return
    async with lock:
        rc, text = await capture(JOBS[name])
    tail = text[-MAX_AUTO_CHARS:]
    if rc == 0:
        if st["notified"]:
            await notify(app, f"AUTO {name}: no longer failing.")
        st.update(fails=0, sig=None, notified=False, next=0.0)
        if "use --force" in text:          # image and compose unchanged: stay quiet
            return
        log.info("AUTO  %s deployed", name)
        await notify(app, f"AUTO {name}: deployed a new build\n{tail}")
        return
    lines = [l for l in text.splitlines() if l.strip()]
    sig = f"{rc}:{lines[-1] if lines else ''}"
    if sig == st["sig"]:
        st["fails"] += 1
    else:
        st.update(sig=sig, fails=1, notified=False)
    st["next"] = time.monotonic() + min(AUTO_INTERVAL * 2 ** st["fails"], 1800)  # back off further after each failure, capped at 30 minutes
    log.error("AUTO  %s failed rc=%s (%s time(s) in a row): %s", name, rc, st["fails"], sig[:200])
    if st["fails"] >= 2 and not st["notified"]:     # a transient failure (network, tag not propagated yet) shouldn't be noisy
        st["notified"] = True
        await notify(app, f"AUTO {name}: REPEATED FAILURE (rc={rc}). The bot will stay quiet until this clears up or changes. "
                          f"/auto_off to pause.\n{tail}")


async def auto_loop(app: Application) -> None:
    await asyncio.sleep(30)                 # let the bot finish starting up
    while True:
        if auto_enabled:
            for name in AUTO_JOBS:
                try:
                    await auto_tick(app, name)
                except Exception:
                    log.exception("AUTO  %s: unexpected error", name)
        await asyncio.sleep(AUTO_INTERVAL)


async def cmd_auto(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    global auto_enabled
    if not authorized(update):
        log.warning("DENY  /auto denied: %s", who(update))
        return
    cmd = update.message.text.split()[0].lstrip("/").split("@")[0]
    if cmd == "auto_off":
        auto_enabled = False
    elif cmd == "auto_on":
        auto_enabled = True
    log.info("AUTO  %s by %s", cmd, who(update))
    await update.message.reply_text(
        f"Auto-deploy: {'ON' if auto_enabled else 'OFF'} (every {AUTO_INTERVAL}s)\n"
        f"Watching: {', '.join(AUTO_JOBS) or '(none)'}\n"
        "A bot restart will turn this back on automatically."
    )


async def on_error(update: object, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    err = ctx.error
    if isinstance(err, (NetworkError, TimedOut)):
        # a brief network/DNS blip: the library retries on its own, no need to print a full traceback
        log.warning("NET   lost connection to Telegram (%s: %s), retrying automatically", type(err).__name__, str(err)[:150])
        return
    log.error("ERROR while handling an update: %s", update, exc_info=err)


NET_DEAD = int(os.environ.get("NET_DEAD_SECONDS", "900"))


async def net_watchdog(app: Application) -> None:
    """Pings Telegram every 30s. If it's been down longer than NET_DEAD_SECONDS, exit so systemd restarts the bot
    (the network sometimes stays broken after the host sleeps/changes networks, and the bot just sits there instead
    of recovering on its own)."""
    down_since = None
    while True:
        await asyncio.sleep(30)
        try:
            await asyncio.wait_for(app.bot.get_me(), timeout=15)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            now = time.monotonic()
            if down_since is None:
                down_since = now
                log.warning("NET   could not reach Telegram: %s", str(e)[:150])
            elif now - down_since > NET_DEAD:
                log.error("NET   down for more than %ss, exiting so systemd restarts the bot", NET_DEAD)
                os._exit(1)
            continue
        if down_since is not None:
            mins = (time.monotonic() - down_since) / 60
            log.info("NET   recovered after %.1f minute(s)", mins)
            down_since = None
            if ALLOWED_CHAT is not None:
                try:
                    await app.bot.send_message(
                        ALLOWED_CHAT,
                        f"The bot's network connection recovered after {mins:.0f} minute(s) (commands sent during that time may have been delayed).",
                        message_thread_id=THREAD)
                except Exception:
                    pass


# ------------------------------------------------------------- lifecycle ----
async def post_init(app: Application) -> None:
    me = await app.bot.get_me()
    cmds = [BotCommand("id", "Show chat_id / user_id"), BotCommand("help", "Show the folder tree and deploy commands"),
            BotCommand("auto_status", "Show auto-deploy status"),
            BotCommand("auto_on", "Turn auto-deploy on"), BotCommand("auto_off", "Pause auto-deploy")]
    cmds += [BotCommand(n, j["desc"]) for n, j in JOBS.items()]
    try:
        await app.bot.set_my_commands(cmds)
    except Exception:
        log.exception("Could not set the command menu")
    app.bot_data["auto_task"] = asyncio.create_task(auto_loop(app))
    app.bot_data["net_task"] = asyncio.create_task(net_watchdog(app))
    log.info("Bot online: @%s (id=%s) on host %s", me.username, me.id, socket.gethostname())
    log.info("Config: chat=%s, users=%s, ci_bots=%s, open_readonly=%s, jobs=%s",
             ALLOWED_CHAT, sorted(ALLOWED_USERS) or "(empty)", sorted(CI_BOT_IDS) or "(empty)", OPEN_READONLY, list(JOBS))

    if ALLOWED_CHAT is None:
        log.warning("ALLOWED_CHAT_ID is not set: only /id will work. Type /id in the group to get it.")
        return
    try:
        await app.bot.send_message(
            ALLOWED_CHAT,
            f"Bot online on {socket.gethostname()}\nAuto-deploy: {', '.join(AUTO_JOBS) or '(off)'} every {AUTO_INTERVAL}s\nType /help to see the commands",
            message_thread_id=THREAD,
        )
        log.info("Sent the online notice to chat %s", ALLOWED_CHAT)
    except Exception:
        log.exception("Could not send the online notice (has the bot been added to the group yet?)")


async def post_shutdown(app: Application) -> None:
    log.info("Bot shutting down")


def main() -> None:
    app = (
        Application.builder()
        .token(TOKEN)
        .connect_timeout(15).read_timeout(20).write_timeout(20).pool_timeout(15)
        .get_updates_read_timeout(40)
        .post_init(post_init)
        .post_shutdown(post_shutdown)
        .build()
    )
    app.add_handler(MessageHandler(filters.ALL, log_incoming), group=-1)
    app.add_handler(CommandHandler("id", cmd_id))
    app.add_handler(CommandHandler("help", cmd_help))
    for c in ("auto_on", "auto_off", "auto_status"):
        app.add_handler(CommandHandler(c, cmd_auto))
    for name in JOBS:
        app.add_handler(CommandHandler(name, run_job))
    app.add_error_handler(on_error)

    log.info("Starting up, long polling...")
    app.run_polling(allowed_updates=Update.ALL_TYPES, bootstrap_retries=-1)


if __name__ == "__main__":
    main()
