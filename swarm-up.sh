#!/usr/bin/env bash
# bot-swarm-init/swarm-up.sh — single-command bootstrap from SSH to ready
# Claude Code coord session.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/tim-po/bot-swarm-init/main/swarm-up.sh | bash
#
# What it does, in order:
#   1. Runs init.sh if bot-swarm isn't installed (host tooling + worker)
#   2. Sources shell env so node/uv/gh are on PATH
#   3. Prompts for sudo to enable-linger so services survive logout
#   4. Prompts for gh auth login if not authenticated (claude-memory is private)
#   5. Clones claude-memory + installs the daily reflector cron
#   6. Starts the worker daemon (systemd-user)
#   7. Launches a detached tmux 'coord' session running `claude`
#   8. Tells you: `tmux attach -t coord` then `/swarm-up` to load context
#
# Idempotent: safe to re-run; each step skips itself if already done.

set -euo pipefail

LOG_PREFIX="[swarm-up]"
log()  { printf "%s %s\n" "$LOG_PREFIX" "$*"; }
die()  { printf "%s FAIL: %s\n" "$LOG_PREFIX" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

USER_NAME="${USER:-$(id -un)}"
SWARM_HOME="${SWARM_HOME:-$HOME/bot-swarm}"

# -------------------------------------------------------------------------
# 1. Host bootstrap via init.sh
# -------------------------------------------------------------------------
if [[ ! -d "$SWARM_HOME/worker" ]]; then
  log "running init.sh (installs nvm/Node, uv, Claude Code, gh, worker)"
  curl -sL https://raw.githubusercontent.com/tim-po/bot-swarm-init/main/init.sh | bash
else
  log "bot-swarm already installed at $SWARM_HOME"
fi

# -------------------------------------------------------------------------
# 2. Source shell env so the rest of this script finds node/uv/gh
# -------------------------------------------------------------------------
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# shellcheck disable=SC1091
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"
export PATH="$HOME/.local/bin:$PATH"

# Sanity-check tools
have gh    || die "gh not on PATH after init.sh (expected at ~/.local/bin/gh)"
have claude || die "claude not on PATH after init.sh"

# -------------------------------------------------------------------------
# 3. systemd-user linger (sudo password prompt — interactive)
# -------------------------------------------------------------------------
if loginctl show-user "$USER_NAME" 2>/dev/null | grep -q "Linger=yes"; then
  log "linger already enabled for $USER_NAME"
else
  echo
  log "Enabling systemd-user linger so services survive your SSH logout."
  log "You will be prompted for your sudo password:"
  sudo loginctl enable-linger "$USER_NAME"
fi

# -------------------------------------------------------------------------
# 4. gh authentication (browser/code prompt — interactive)
# -------------------------------------------------------------------------
if gh auth status >/dev/null 2>&1; then
  log "gh already authenticated"
else
  echo
  log "Authenticating gh so we can clone the private claude-memory repo."
  log "Follow the prompts (GitHub.com → HTTPS → web browser is easiest):"
  gh auth login
fi

# -------------------------------------------------------------------------
# 5. claude-memory clone + cron
# -------------------------------------------------------------------------
if [[ -d "$HOME/claude-memory" ]]; then
  log "claude-memory already cloned; pulling latest"
  ( cd "$HOME/claude-memory" && git pull --rebase --autostash --quiet ) || true
else
  log "cloning tim-po/claude-memory"
  gh repo clone tim-po/claude-memory "$HOME/claude-memory"
fi

if ! crontab -l 2>/dev/null | grep -q 'reflect.sh daily'; then
  log "installing daily reflector cron"
  "$HOME/claude-memory/scripts/install-cron.sh" >/dev/null
else
  log "daily reflector cron already installed"
fi

# -------------------------------------------------------------------------
# 6. Start the worker daemon
# -------------------------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now bot-swarm-worker.service >/dev/null 2>&1 || true
if systemctl --user is-active bot-swarm-worker.service >/dev/null 2>&1; then
  log "worker daemon active"
else
  log "WARN worker daemon not active — diagnose with: journalctl --user -u bot-swarm-worker.service"
fi

# -------------------------------------------------------------------------
# 7. Launch a detached tmux 'coord' session running `claude`
# -------------------------------------------------------------------------
if tmux has-session -t coord 2>/dev/null; then
  log "tmux session 'coord' already exists"
else
  log "starting tmux session 'coord' with claude"
  tmux new -d -s coord -- bash -lc "cd ~ && claude"
fi

# -------------------------------------------------------------------------
# 8. Final instructions
# -------------------------------------------------------------------------
cat <<EOF

==============================================================
$LOG_PREFIX everything installed, worker running, session ready.

  Attach to your coord session:
       tmux attach -t coord

  Once inside Claude, type:
       /swarm-up

  (idempotent — it'll just verify state, refresh memory, and report.)
==============================================================
EOF
