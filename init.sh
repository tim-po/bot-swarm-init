#!/usr/bin/env bash
# bot-swarm-init — bootstrap a fresh Ubuntu/Debian VPS into a working
# swarm-coordinator host. Run as the unprivileged user that will own the swarm
# (NOT root). Assumes sudo is available for ONE command (linger), surfaced at
# the end. Idempotent: safe to re-run.
#
# Usage:
#   curl -sL https://<your-host>/bot-swarm-init/init.sh | bash
#   # or, after cloning the repo:
#   ./init.sh
#
# Optional env vars:
#   SWARM_USER       — user the swarm runs as (default: $USER)
#   SWARM_HOME       — install root for bot-swarm/ (default: $HOME/bot-swarm)
#   SWARM_PROJECT    — primary project slug to scaffold (optional)
#   SWARM_PROJECT_REPO — git URL to clone for SWARM_PROJECT (optional)
#   TG_PROXY_VIA_XRAY — set "1" if Telegram is blocked at the host's ISP and
#                       you have an xray-vpn container with a warp outbound
#                       (sets up the HTTP-proxy inbound + wrapper script)

set -euo pipefail

# -------------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------------
SWARM_USER="${SWARM_USER:-${USER:-$(id -un)}}"
SWARM_HOME="${SWARM_HOME:-$HOME/bot-swarm}"
INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[swarm-init]"

log()  { printf "%s %s\n" "$LOG_PREFIX" "$*"; }
die()  { printf "%s FAIL: %s\n" "$LOG_PREFIX" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ "$(id -u)" -eq 0 ]]; then
  die "do not run as root — run as the user that will own the swarm"
fi
if ! have curl; then die "curl missing — sudo apt install curl"; fi

log "user=$SWARM_USER, swarm_home=$SWARM_HOME, init_dir=$INIT_DIR"

# -------------------------------------------------------------------------
# 1. Node.js via nvm (~/.nvm/, no sudo)
# -------------------------------------------------------------------------
if ! have node || [[ ! -d "$HOME/.nvm" ]]; then
  log "installing nvm + Node LTS"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash > /tmp/nvm-install.log 2>&1
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts >> /tmp/nvm-install.log 2>&1
else
  log "Node already installed: $(node --version 2>/dev/null || echo unknown)"
fi

# Ensure login shells pick up nvm
if [[ ! -f "$HOME/.bash_profile" ]] || ! grep -q ".nvm/nvm.sh" "$HOME/.bash_profile" 2>/dev/null; then
  cat > "$HOME/.bash_profile" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -f ~/.bashrc ] && . ~/.bashrc
[ -f ~/.local/bin/env ] && source ~/.local/bin/env
EOF
fi

# -------------------------------------------------------------------------
# 2. uv (Python venv + package manager, no sudo, no python3-venv apt dep)
# -------------------------------------------------------------------------
if ! have uv && [[ ! -x "$HOME/.local/bin/uv" ]]; then
  log "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh > /tmp/uv-install.log 2>&1
else
  log "uv already installed"
fi
# shellcheck disable=SC1091
[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"

# -------------------------------------------------------------------------
# 3. Claude Code (npm global via nvm)
# -------------------------------------------------------------------------
# shellcheck disable=SC1091
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
if ! have claude; then
  log "installing Claude Code"
  npm install -g @anthropic-ai/claude-code --no-audit --no-fund > /tmp/claude-install.log 2>&1
else
  log "Claude Code already installed: $(claude --version 2>/dev/null || echo unknown)"
fi

# -------------------------------------------------------------------------
# 3b. GitHub CLI (`gh`) — needed for cloning private repos (claude-memory,
#     project repos). Install via the official tarball into ~/.local/bin
#     (no sudo). `gh auth login` is still a one-time interactive step the
#     operator runs after init.sh finishes.
# -------------------------------------------------------------------------
if ! have gh && [[ ! -x "$HOME/.local/bin/gh" ]]; then
  log "installing GitHub CLI (gh) — no sudo"
  GH_VERSION="2.62.0"  # bump when stale; check https://github.com/cli/cli/releases
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  GH_ARCH="amd64" ;;
    aarch64|arm64) GH_ARCH="arm64" ;;
    *)       log "WARN: unknown arch $ARCH for gh; skipping" ; GH_ARCH="" ;;
  esac
  if [[ -n "$GH_ARCH" ]]; then
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/man/man1"
    GH_TGZ="/tmp/gh-${GH_VERSION}.tgz"
    curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" -o "$GH_TGZ"
    tar -xzf "$GH_TGZ" -C /tmp/
    cp "/tmp/gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh" "$HOME/.local/bin/gh"
    chmod +x "$HOME/.local/bin/gh"
    rm -rf "$GH_TGZ" "/tmp/gh_${GH_VERSION}_linux_${GH_ARCH}"
    log "gh installed: $($HOME/.local/bin/gh --version 2>/dev/null | head -1)"
  fi
else
  log "gh already available: $(command -v gh 2>/dev/null || echo $HOME/.local/bin/gh)"
fi

# -------------------------------------------------------------------------
# 4. Lay down ~/bot-swarm/ from vendor/ payload
# -------------------------------------------------------------------------
if [[ ! -d "$SWARM_HOME" ]]; then
  log "creating $SWARM_HOME from vendored payload"
  mkdir -p "$SWARM_HOME"
  if [[ -f "$INIT_DIR/vendor/bot-swarm.tar.gz" ]]; then
    tar -xzf "$INIT_DIR/vendor/bot-swarm.tar.gz" -C "$SWARM_HOME" --strip-components=1
  elif [[ -d "$INIT_DIR/vendor/bot-swarm" ]]; then
    cp -r "$INIT_DIR/vendor/bot-swarm/." "$SWARM_HOME/"
  else
    die "no vendored bot-swarm payload at $INIT_DIR/vendor/"
  fi
else
  log "$SWARM_HOME already exists — skipping vendor extraction (re-run init.sh after manual rsync if updating)"
fi

# Python venv for the worker
if [[ ! -x "$SWARM_HOME/worker/.venv/bin/python" ]]; then
  log "creating worker venv with uv"
  ( cd "$SWARM_HOME/worker" && uv venv .venv --python=3.13 > /tmp/uv-venv.log 2>&1 && uv pip install --python .venv/bin/python -e . > /tmp/uv-install-worker.log 2>&1 )
else
  log "worker venv already exists"
fi

# Path rewrite (in case payload was vendored with absolute paths from a build host)
if grep -rl "/home/__SWARM_USER__" "$SWARM_HOME" >/dev/null 2>&1; then
  log "rewriting __SWARM_USER__ placeholders in vendored config"
  grep -rl "/home/__SWARM_USER__" "$SWARM_HOME" 2>/dev/null | xargs sed -i "s|/home/__SWARM_USER__|$HOME|g"
fi

# -------------------------------------------------------------------------
# 5. Seed coord auto-memory at ~/.claude/projects/<cwd-encoded>/memory/
# -------------------------------------------------------------------------
ENCODED_CWD="-$(echo "$SWARM_HOME" | sed 's|/|-|g' | sed 's|^-||')"
MEMORY_DIR="$HOME/.claude/projects/$ENCODED_CWD/memory"
mkdir -p "$MEMORY_DIR"
if [[ -d "$INIT_DIR/seed-memory" ]] && [[ ! -f "$MEMORY_DIR/MEMORY.md" ]]; then
  log "seeding coord memory at $MEMORY_DIR"
  cp -r "$INIT_DIR/seed-memory/." "$MEMORY_DIR/"
else
  log "coord memory already seeded (or no seed-memory in init payload)"
fi

# -------------------------------------------------------------------------
# 5b. User-level Claude Code skills (e.g. /swarm-up)
# -------------------------------------------------------------------------
SKILLS_DIR="$HOME/.claude/skills"
if [[ -d "$INIT_DIR/skills" ]]; then
  mkdir -p "$SKILLS_DIR"
  for skill_dir in "$INIT_DIR/skills"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    target="$SKILLS_DIR/$skill_name"
    if [[ ! -d "$target" ]]; then
      log "installing skill /$skill_name → $target"
      cp -r "$skill_dir" "$target"
    else
      log "skill /$skill_name already installed — skipping (delete to refresh)"
    fi
  done
fi

# -------------------------------------------------------------------------
# 6. systemd-user units
# -------------------------------------------------------------------------
SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"

if [[ -d "$INIT_DIR/templates/systemd" ]]; then
  log "installing systemd-user unit templates"
  for unit_template in "$INIT_DIR/templates/systemd"/*.service; do
    [[ -e "$unit_template" ]] || continue
    unit_name="$(basename "$unit_template")"
    sed -e "s|__SWARM_HOME__|$SWARM_HOME|g" \
        -e "s|__NVM_NODE__|$(ls -t "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | head -1)|g" \
        "$unit_template" > "$SYSTEMD_DIR/$unit_name"
  done
fi

if have systemctl; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  systemctl --user daemon-reload || true
  # Auto-start the worker daemon. Idempotent: enable--now is a no-op if
  # already running. Persistence across logout still requires loginctl
  # enable-linger — surfaced in the epilogue.
  if systemctl --user enable --now bot-swarm-worker.service >/dev/null 2>&1; then
    log "bot-swarm-worker.service started"
  else
    log "WARN: bot-swarm-worker.service did not start; run 'systemctl --user enable --now bot-swarm-worker.service' manually"
  fi
fi

# -------------------------------------------------------------------------
# 7. Optional: Telegram-via-xray proxy wrapper
# -------------------------------------------------------------------------
if [[ "${TG_PROXY_VIA_XRAY:-0}" == "1" ]] && [[ -f "$INIT_DIR/templates/proxy-wrapper.sh" ]]; then
  log "installing xray-proxy wrapper at ~/bin/with-tg-proxy.sh"
  mkdir -p "$HOME/bin"
  cp "$INIT_DIR/templates/proxy-wrapper.sh" "$HOME/bin/with-tg-proxy.sh"
  chmod +x "$HOME/bin/with-tg-proxy.sh"
  log "NOTE: you must separately add an HTTP-proxy inbound to your xray config (see seed-memory/known-quirks.md)"
fi

# -------------------------------------------------------------------------
# 8. Optional: register a primary project (greenfield clone OR existing repo)
# -------------------------------------------------------------------------
# Three modes:
#   - SWARM_PROJECT + SWARM_PROJECT_REPO: clone the repo to ~/$SWARM_PROJECT
#   - SWARM_PROJECT + SWARM_PROJECT_PATH: register an existing repo at that path
#   - SWARM_PROJECT alone: assume ~/$SWARM_PROJECT and register if it exists
#
# We NEVER touch the project's .claude/ directory or its .git/. The swarm
# adds bookkeeping in $SWARM_HOME/data/<slug>/ only.
if [[ -n "${SWARM_PROJECT:-}" ]]; then
  PROJECT_PATH="${SWARM_PROJECT_PATH:-$HOME/$SWARM_PROJECT}"

  if [[ ! -d "$PROJECT_PATH" ]] && [[ -n "${SWARM_PROJECT_REPO:-}" ]]; then
    log "cloning $SWARM_PROJECT_REPO → $PROJECT_PATH"
    git clone "$SWARM_PROJECT_REPO" "$PROJECT_PATH"
  fi

  if [[ -d "$PROJECT_PATH" ]]; then
    log "registering project $SWARM_PROJECT at $PROJECT_PATH"
    # Warn if the project has its own .claude config — we don't touch it,
    # but the operator should know there are two .claude layers in play.
    if [[ -d "$PROJECT_PATH/.claude" ]]; then
      log "NOTE: $PROJECT_PATH has its own .claude/ — left untouched. Your project hooks/settings continue to apply when you 'claude' from that dir."
    fi
    mkdir -p "$SWARM_HOME/data/$SWARM_PROJECT"/{backlog,initiatives,reports,experts,_chat,sessions}
    # Add to projects.toml if not present
    if ! grep -q "^\[projects\.$SWARM_PROJECT\]" "$SWARM_HOME/config/projects.toml" 2>/dev/null; then
      cat >> "$SWARM_HOME/config/projects.toml" <<EOF

[projects.$SWARM_PROJECT]
slug = "$SWARM_PROJECT"
display_name = "$SWARM_PROJECT"
repo_path = "$PROJECT_PATH"
deploy_branch = ""
master_branch = ""
prod_url = ""
staging_url = ""
dev_url = ""
deploy_targets = []
tg_chat = ""
EOF
    fi
  else
    log "SWARM_PROJECT=$SWARM_PROJECT set but no repo found at $PROJECT_PATH (and no SWARM_PROJECT_REPO to clone). Skipping project registration."
  fi
fi

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
cat <<EOF

$LOG_PREFIX install complete.

The worker socket daemon has been started. Two interactive steps remain
(both one-time per host, both security-required so init.sh cannot do
them for you):

  1. Make services survive logout (sudo password):
       sudo loginctl enable-linger $SWARM_USER
  2. Authenticate gh (interactive token / browser flow):
       ~/.local/bin/gh auth login

  Paste-able as one line:
     sudo loginctl enable-linger $SWARM_USER && ~/.local/bin/gh auth login

After those, start a Claude Code session and the /swarm-up skill finishes
everything else (clones claude-memory, installs the daily reflector cron,
loads identity + project context):

       tmux new -s coord
       cd $SWARM_HOME${SWARM_PROJECT:+ # or cd $HOME/$SWARM_PROJECT}
       claude
       # In the prompt: /swarm-up

The seeded auto-memory at $MEMORY_DIR points the new coord at the swarm
protocol — read MEMORY.md if you want background.

If Telegram is reachable directly on this host, also enable:
       systemctl --user enable --now planlink-tg-poller.service
       systemctl --user enable --now bot-swarm-tg-bridge.service
(Or with TG_PROXY_VIA_XRAY=1, after configuring xray HTTP-proxy inbound.)
EOF
