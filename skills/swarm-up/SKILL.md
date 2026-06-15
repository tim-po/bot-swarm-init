---
name: swarm-up
description: Bootstrap this Claude Code session as a bot-swarm coordinator — pulls latest claude-memory, verifies/starts the worker socket, loads identity + project context, and offers to spawn expert sessions. Trigger when the user types "/swarm-up", or asks to "bootstrap swarm", "make this session coord", "wake up coord", "initialize as swarm coordinator", or starts a fresh session expecting to dispatch to swarm experts.
version: 1.0.0
---

# /swarm-up

Turn the current Claude Code session into a bot-swarm coordinator with full context loaded from the persistent memory layer.

## When this skill fires

- User explicitly types `/swarm-up`
- User asks to "bootstrap swarm", "wake up coord", "make this session the coordinator", "initialize swarm", or similar
- User opens a fresh session with intent to dispatch work to swarm experts (planner, backend-expert, frontend-expert, testcoord)

If the user is asking about something unrelated (regular coding, research, etc.), do NOT fire this skill.

## What this skill does

Execute these steps in order. After each step, log a one-line status to the user so they can follow what's happening.

### 1. Detect host state

Check what's already installed. The skill handles three host states (fresh, partial, ready) gracefully — each step is idempotent.

```bash
test -d ~/bot-swarm/worker && test -S ~/bot-swarm/data/_sock/worker.sock && echo "worker-ready" || echo "needs-bootstrap"
test -d ~/claude-memory && echo "memory-present" || echo "memory-missing"
```

If `needs-bootstrap`: tell the user this host hasn't been swarm-initialized and direct them to run `bot-swarm-init/init.sh` first. Do NOT try to install from inside the skill — that's init.sh's job.

### 2. Pull / clone claude-memory

```bash
if [ -d ~/claude-memory ]; then
  cd ~/claude-memory && git pull --rebase --autostash
else
  gh repo clone tim-po1/claude-memory ~/claude-memory
fi
```

If `gh` isn't authenticated and the clone fails, fall back to telling the user: "`gh auth login` then re-run `/swarm-up`".

### 3. Verify worker daemon is running

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user is-active bot-swarm-worker.service 2>/dev/null
```

If inactive, try `systemctl --user start bot-swarm-worker.service`. If still inactive after start, surface the error.

### 4. Load identity + relevant project context

Read these files into context (use the Read tool):

- `~/claude-memory/README.md` — how the memory layer works
- `~/claude-memory/identity/self.md` — operating patterns
- `~/claude-memory/lessons/` — list and skim names; read any whose title plausibly relates to the user's likely task
- `~/claude-memory/projects/<slug>/` — IF the cwd matches a known project, OR the user mentions one. Auto-detect by checking `~/bot-swarm/config/projects.toml` and matching `$PWD` against `repo_path` entries.

If a project matches, read `projects/<slug>/current-state.md` (if it exists) and `projects/<slug>/conventions.md`.

### 5. Discover the swarm state

```bash
curl -sS --unix-socket ~/bot-swarm/data/_sock/worker.sock \
  -X POST -H 'Content-Type: application/json' -d '{"slug":"<detected_slug>"}' \
  http://w/actions/list_sessions
```

Note which expert roles are already alive vs which would need spawning.

### 6. Report status

Reply with a single short block:

```
swarm-up ready.
  host:      <fresh | partial | ready>
  memory:    pulled to <commit hash>; identity + <N lessons skimmed>
  project:   <slug or "none detected">
  worker:    active (socket at ...)
  sessions:  <list of active SIDs>, or "none yet"
  context:   <1-2 relevant items from claude-memory>
```

Then ask the user what they want to dispatch.

### 7. Offer expert-spawn (do NOT auto-spawn)

If the user mentions wanting to dispatch work to a role that has no live session, ask first before running `spawn_session`. Don't blindly create planner+backend+frontend+testcoord on every invocation — that burns subscription tokens. Spawn on demand.

## What this skill does NOT do

- Install bot-swarm-init or any of its dependencies. That's `bot-swarm-init/init.sh`'s job; the skill assumes it's already been run.
- Authenticate `gh`. Interactive; user does it manually after init.sh.
- Spawn expert sessions automatically. Coord-on-demand pattern only.
- Modify any project's `.claude/` configuration.

## Honest framing for the user

This skill makes the current session **a coordinator with context loaded** — same model, same accumulated memory. It does not make the session magically continuous with prior sessions; it loads the persistent memory layer so the model produces consistent judgment.

## Failure modes

- If `~/bot-swarm/` doesn't exist: stop, tell user to run init.sh.
- If `gh auth` failed: tell user to authenticate, don't loop.
- If `claude-memory` repo has uncommitted local changes that block pull: surface the conflict; let user choose.
- If the worker daemon refuses to start: capture journalctl tail, surface to user.

When in doubt, stop and surface to the user rather than guessing.
