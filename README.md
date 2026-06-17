# bot-swarm-init

Bootstrap a fresh Ubuntu/Debian host into a working bot-swarm coordinator with a Claude Code session ready to dispatch.

## Quick start — one curl

```bash
ssh your-vps
curl -sL https://raw.githubusercontent.com/tim-po/bot-swarm-init/main/swarm-up.sh | bash
```

`swarm-up.sh` runs `init.sh` (installs nvm/Node, uv, Claude Code, gh, the worker), prompts you for two interactive things mid-script:

- **sudo password** for `loginctl enable-linger` (so services survive logout)
- **gh auth** to clone the private `claude-memory` repo

…then clones memory and starts the worker daemon. To start (or attach to) your coord session, one word:

```bash
swarm
```

That opens a tmux session named `coord` running Claude Code with `/swarm-up` auto-loaded. Detach with `Ctrl-b d`; re-attach later with the same single command. Status check: `swarm --status`. Force a fresh session: `swarm --new`.

`/swarm-up` is the in-session skill (installed by init.sh) that verifies state, refreshes memory, and loads project context.

## Lower-level entry points

## Adding a Telegram bot per project

After `init.sh` is done, each project gets its own bot (one bot = one project; sharing tokens across projects races on `getUpdates`).

```bash
# 1. Make a bot via @BotFather → /newbot → grab the token.
# 2. Wire it to a registered project:
~/bin/swarm-add-tg-bot <slug> <bot_token>

# Optional 3rd arg: a specific coord SID to route to.
# If omitted, the helper picks the most-recently-active coord in the slug.
```

The helper creates `~/bot-swarm/data/<slug>/telegram/{bridge.py,.env,bridge.log}`, writes a systemd-user unit `bot-swarm-tg-bridge-<slug>.service`, enables and starts it, verifies the token with Telegram's `getMe`, and reports the bot's username. Auto-detects the `~/bin/with-tg-proxy.sh` wrapper (installed by `init.sh` when `TG_PROXY_VIA_XRAY=1`) for hosts where the ISP blocks Telegram directly.

Idempotent — re-running with the same slug refreshes the `.env` and the unit, so it's also how you rotate a token.

## Lower-level entry points

If you want host bootstrap WITHOUT auto-launching a coord session:

```bash
# Option A — clone + run
git clone https://github.com/tim-po/bot-swarm-init.git
cd bot-swarm-init && ./init.sh

# Option B — one-shot init pipe (no auto-session, no memory clone)
curl -sL https://raw.githubusercontent.com/tim-po/bot-swarm-init/main/init.sh | bash
```

Then follow the printed instructions. The whole flow:

```bash
ssh your-vps
# (run one of the install options above)
sudo loginctl enable-linger $(whoami)   # one-time; makes services survive logout
systemctl --user enable --now bot-swarm-worker.service

tmux new -s coord
cd ~/bot-swarm
claude
# Interactive auth on first run. The coord reads seeded memory at
# ~/.claude/projects/-home-<user>-bot-swarm/memory/ — knows the protocol from minute one.
```

## What you get

| | |
|---|---|
| `~/bot-swarm/` | Worker code + config skeleton + data dir layout |
| `~/.nvm/`, `~/.local/bin/uv`, `~/.local/bin/claude` | User-space tooling, no sudo (except linger) |
| `~/.config/systemd/user/bot-swarm-worker.service` | Worker socket daemon, auto-restart |
| `~/.claude/projects/.../memory/{MEMORY,swarm-protocol,dispatch-patterns,known-quirks,hermes-role}.md` | Distilled coord knowledge, seeded so the first Claude on this host can drive the swarm without reading source |
| `~/bin/with-tg-proxy.sh` (if `TG_PROXY_VIA_XRAY=1`) | Wrapper that routes outbound HTTP(S) through an xray container's WARP-backed HTTP-proxy inbound |

## Optional env vars

```bash
SWARM_USER=claude           # who owns the install (default: $USER)
SWARM_HOME=~/bot-swarm      # install root (default)
SWARM_PROJECT=myapp         # primary project slug — scaffolded under data/myapp/
SWARM_PROJECT_REPO=git@...  # cloned to ~/$SWARM_PROJECT if provided (greenfield)
SWARM_PROJECT_PATH=/path    # OR point at an existing repo (attach mode — won't clone or clobber)
TG_PROXY_VIA_XRAY=1         # install the proxy wrapper (needs xray-vpn container)
```

### Three project modes

| You set | Init does |
|---|---|
| `SWARM_PROJECT=foo SWARM_PROJECT_REPO=git@...` | Greenfield. Clones the repo to `~/foo` and registers it. |
| `SWARM_PROJECT=foo SWARM_PROJECT_PATH=/home/user/foo` | **Attach mode** — registers an existing repo. NEVER touches its `.git/` or `.claude/`. |
| `SWARM_PROJECT=foo` alone | Looks for `~/foo`; if present, registers as attach mode. |

## What does NOT ship

- **No project data** (PlanLink-specific work, expert memory dirs, captured Telegram corpora). The init lays down a clean swarm skeleton; you bring or grow your own project state.
- **No Telegram bridge / poller configuration** — those are project-specific. Look at the proxy-wrapper + the seed-memory's `known-quirks.md` to wire one up.
- **No Hermes integration** — see `seed-memory/hermes-role.md` for the Phase-2 stub.

## Updating

`init.sh` is idempotent — re-running it skips existing installs. To pull a newer worker:

```bash
cd bot-swarm-init && git pull
# then on the target:
rsync -aH bot-swarm-init/vendor/bot-swarm/ ~/bot-swarm/    # or re-extract
( cd ~/bot-swarm/worker && uv pip install --python .venv/bin/python -e . )
systemctl --user restart bot-swarm-worker.service
```

## Layout

```
bot-swarm-init/
├── init.sh                 # main entrypoint
├── README.md               # you are here
├── seed-memory/            # distilled coord knowledge → ~/.claude/.../memory/
│   ├── MEMORY.md
│   ├── swarm-protocol.md
│   ├── dispatch-patterns.md
│   ├── known-quirks.md
│   └── hermes-role.md
├── templates/
│   ├── systemd/            # *.service unit files with __SWARM_HOME__ placeholders
│   └── proxy-wrapper.sh    # xray HTTP-proxy resolver
└── vendor/
    └── bot-swarm.tar.gz    # worker code + config skeleton
```

## Provenance

Built 2026-06-11 by coord-p17 (PlanLink swarm, Mac) after driving the PlanLink build Jun 8–11. The seed-memory captures workarounds and patterns proven during that work — see `seed-memory/dispatch-patterns.md` for the orchestration patterns and `known-quirks.md` for friction we hit (and fixed, in some cases — check the bot-swarm self-project backlog for fix status).

This package is the way to bootstrap a "coord with experience" rather than a generic Claude. The next coord on the next host gets 3 days of context for free.
