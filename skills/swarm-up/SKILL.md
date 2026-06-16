---
name: swarm-up
description: Bootstrap this Claude Code session as a bot-swarm coordinator on ANY host — installs tooling on a fresh host (nvm/Node, uv, Claude Code, gh), clones bot-swarm-init, runs init.sh, pulls claude-memory, starts the worker daemon, loads identity + project context, reports status. Trigger when the user types "/swarm-up", or asks to "bootstrap swarm", "make this session coord", "wake up coord", "initialize as swarm coordinator", or starts a fresh session expecting to dispatch to swarm experts.
version: 2.0.0
---

# /swarm-up

Turn the current Claude Code session into a bot-swarm coordinator, with full host setup if needed. Idempotent — safe to invoke on a host that's already fully provisioned (it'll just refresh memory and verify state).

## When this skill fires

- User explicitly types `/swarm-up`
- User asks to "bootstrap swarm", "wake up coord", "make this session the coordinator", "initialize swarm", or similar phrasing
- User opens a fresh session intending to dispatch work to swarm experts

If the user is asking about something unrelated, do NOT fire this skill.

## Execution order

Execute these phases sequentially. After each phase, log a one-line status so the user can follow what's happening. **Each phase is idempotent** — safe to skip if already complete.

### Phase 1 — Detect host state

```bash
test -d "$HOME/bot-swarm/worker" && echo "bot-swarm-present" || echo "bot-swarm-missing"
test -d "$HOME/claude-memory" && echo "claude-memory-present" || echo "claude-memory-missing"
test -x "$HOME/.local/bin/gh" || command -v gh >/dev/null && echo "gh-present" || echo "gh-missing"
```

Branch on the results. Report what's missing in one line.

### Phase 2 — Install bot-swarm if missing (FULL SETUP)

If `~/bot-swarm/` doesn't exist, this is a fresh host. Do the full install:

```bash
# Clone the public init repo to /tmp and run it. init.sh installs nvm+Node,
# uv, Claude Code, gh (via tarball), the worker daemon, seed memory, systemd
# unit files, and the /swarm-up skill itself.
git clone https://github.com/tim-po/bot-swarm-init.git /tmp/bot-swarm-init
cd /tmp/bot-swarm-init
./init.sh
```

If init.sh exits non-zero, surface the error and stop. Do NOT continue with later phases.

After init.sh finishes, source the new shell profile so the rest of the skill can find `node`, `uv`, `gh`:

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"
export PATH="$HOME/.local/bin:$PATH"
```

### Phase 3 — Pull or clone claude-memory

`claude-memory` is PRIVATE. It needs `gh` authenticated.

```bash
if [ -d "$HOME/claude-memory" ]; then
  cd "$HOME/claude-memory" && git pull --rebase --autostash
else
  # Check gh auth first; surface a single clear message if not authenticated
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not authenticated. Run: gh auth login"
    echo "Then re-invoke /swarm-up. Stopping here."
    exit 0
  fi
  gh repo clone tim-po/claude-memory "$HOME/claude-memory"
  "$HOME/claude-memory/scripts/install-cron.sh"
fi
```

If `gh auth login` is needed, do NOT try to launch it from inside the skill (it's interactive and will hang). Just tell the user to run it and re-invoke.

### Phase 4 — Worker daemon

```bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now bot-swarm-worker.service 2>/dev/null || true

# Verify
if systemctl --user is-active bot-swarm-worker.service >/dev/null 2>&1; then
  echo "worker active"
else
  echo "worker not active — check: journalctl --user -u bot-swarm-worker.service"
fi
```

On macOS or hosts without `systemctl`, fall back to:

```bash
# Macs typically don't use systemctl --user; the swarm worker on Mac is usually
# already running in some tmux window. Just verify the socket is alive.
if [ -S "$HOME/bot-swarm/data/_sock/worker.sock" ]; then
  curl -sS --unix-socket "$HOME/bot-swarm/data/_sock/worker.sock" \
    -X POST -d '{}' http://w/openapi.json >/dev/null && echo "worker socket alive"
fi
```

### Phase 5 — Load identity + relevant project context

Use the Read tool on these files:

- `~/claude-memory/README.md` — how the memory layer works
- `~/claude-memory/identity/self.md` — operating patterns
- Skim `~/claude-memory/lessons/` — list filenames; read any whose title plausibly applies

Then detect the active project:

```bash
PWD_NOW="$(pwd)"
for entry in $(grep "^repo_path" "$HOME/bot-swarm/config/projects.toml" 2>/dev/null | sed 's/.*= *//; s/"//g'); do
  if [ "$PWD_NOW" = "$entry" ] || [ "${PWD_NOW#$entry/}" != "$PWD_NOW" ]; then
    # cwd is at or under this project's repo_path
    project_slug="$(grep -B1 "= \"$entry\"" "$HOME/bot-swarm/config/projects.toml" | head -1 | sed 's/\[projects\.//; s/\]//')"
    echo "detected project: $project_slug"
    break
  fi
done
```

If a project is detected, Read `~/claude-memory/projects/<slug>/` files if any exist (current-state.md, conventions.md).

### Phase 6 — Discover swarm state

```bash
curl -sS --unix-socket "$HOME/bot-swarm/data/_sock/worker.sock" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"slug\":\"${project_slug:-planlink}\"}" \
  http://w/actions/list_sessions
```

Parse the JSON; count active vs suspended sessions per role.

### Phase 7 — Status report

Reply with exactly one block:

```
swarm-up ready.
  host:      <fresh-installed | partial-restored | already-ready>
  memory:    pulled to <short commit hash>; <N lessons skimmed>
  project:   <slug or "none detected">
  worker:    <active | inactive | not-applicable>
  sessions:  <comma-separated list of active SIDs by role, or "none yet">
  context:   <1-2 relevant items: a recent decision, a current open loop, etc.>
```

Then ONE follow-up line: "What would you like to dispatch?" — and wait for the user.

### Phase 8 — On-demand expert spawn

Do NOT auto-spawn experts. When the user's task implies needing a role that has no live session, ask first:

> "No backend-expert session is alive. Spawn one? (y/n)"

If yes, use the `spawn_session` action via the worker socket. Pass the standard identity template + the project slug + a brief reflecting the task.

## What this skill does NOT do

- **Does not run `sudo loginctl enable-linger <user>`.** That requires a password prompt; surface it as a one-line recommendation in the final report instead (if services were inactive and would die on logout).
- **Does not authenticate gh.** Interactive; user runs `gh auth login` themselves.
- **Does not modify any project's `.claude/` configuration.**

## Failure modes (handle gracefully — stop, don't loop)

- `git clone https://github.com/tim-po/bot-swarm-init.git` fails (no network, repo gone): report the error verbatim.
- `init.sh` exits non-zero: tail its log to user, stop.
- `gh auth status` fails: tell user `gh auth login` is needed, stop.
- Worker socket exists but the daemon doesn't respond: report and offer `systemctl --user restart`.

When in doubt, stop and surface to the user rather than guessing.

## Honest framing

This skill makes the current session **a coordinator with full host setup and accumulated context loaded** — same model, same memory layer, consistent operating patterns. It does not make the session continuous with prior coord sessions; it loads the persistent layer so the model produces consistent judgment across instances.
