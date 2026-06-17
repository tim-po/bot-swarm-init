#!/usr/bin/env bash
# swarm-add-tg-bot — wire a new Telegram bot to a project's coord inbox.
#
# Usage:
#   swarm-add-tg-bot.sh <slug> <bot_token> [coord_sid]
#
# What it does (per call):
#   1. Validates that <slug> is registered in $SWARM_HOME/config/projects.toml.
#   2. Creates $SWARM_HOME/data/<slug>/telegram/ with bridge.py + .env.
#   3. If coord_sid omitted, picks the most-recently-active coord SID for the
#      slug (or warns and uses a placeholder you can fill in later).
#   4. Writes a per-project systemd-user unit:
#        bot-swarm-tg-bridge-<slug>.service
#      Detects whether ~/bin/with-tg-proxy.sh exists and uses it if so.
#   5. systemctl --user enable --now
#   6. Tails the bridge log so you can verify the bot is polling cleanly.
#
# Idempotent: re-running with the same slug refreshes .env and the unit
# in place; safe to use to rotate a token.
#
# Prereqs (init.sh handles these): worker daemon installed, systemd-user.

set -euo pipefail

LOG_PREFIX="[swarm-add-tg-bot]"
log()  { printf "%s %s\n" "$LOG_PREFIX" "$*"; }
die()  { printf "%s FAIL: %s\n" "$LOG_PREFIX" "$*" >&2; exit 1; }

SLUG="${1:-}"
TOKEN="${2:-}"
COORD_SID="${3:-}"

[[ -n "$SLUG" ]]  || die "missing <slug>. Usage: $0 <slug> <bot_token> [coord_sid]"
[[ -n "$TOKEN" ]] || die "missing <bot_token>"

# Token sanity (Telegram format: <int>:<base64ish>, generally 35-50 chars total)
[[ "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "bot token doesn't look like Telegram format <id>:<rest>"

SWARM_HOME="${SWARM_HOME:-$HOME/bot-swarm}"
PROJECTS_TOML="$SWARM_HOME/config/projects.toml"
TG_DIR="$SWARM_HOME/data/$SLUG/telegram"

# Find the bot-swarm-init payload — script lives at $REPO/scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_SRC="$INIT_REPO/templates/telegram/bridge.py"

# --- 1. Validate slug ---
if ! grep -q "^\[projects\.$SLUG\]" "$PROJECTS_TOML" 2>/dev/null; then
  die "slug '$SLUG' not registered in $PROJECTS_TOML. Run init.sh with SWARM_PROJECT=$SLUG first, or add the entry by hand."
fi
log "slug '$SLUG' registered ✓"

# --- 2. Layout ---
mkdir -p "$TG_DIR"
if [[ ! -f "$BRIDGE_SRC" ]]; then
  die "no bridge.py template at $BRIDGE_SRC — bot-swarm-init payload missing or out of date"
fi
cp "$BRIDGE_SRC" "$TG_DIR/bridge.py"
chmod +x "$TG_DIR/bridge.py"
log "bridge.py installed at $TG_DIR/"

# --- 3. Resolve coord SID ---
if [[ -z "$COORD_SID" ]]; then
  # Ask the worker for active coord sessions in this slug.
  SOCK="$SWARM_HOME/data/_sock/worker.sock"
  if [[ -S "$SOCK" ]]; then
    COORD_SID="$(curl -sS --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
        -d "{\"slug\":\"$SLUG\"}" http://w/actions/list_sessions 2>/dev/null \
      | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    coords = [s for s in d.get('sessions', []) if s.get('role') == 'coordinator' and s.get('status') == 'active']
    if coords:
        coords.sort(key=lambda s: s.get('last_prompt_at') or 0, reverse=True)
        print(coords[0]['sid'])
except Exception:
    pass
" 2>/dev/null)"
  fi
fi
if [[ -z "$COORD_SID" ]]; then
  COORD_SID="S-PLACEHOLDER-coord-pX"
  log "WARN no active coord in slug '$SLUG' — using placeholder $COORD_SID. Edit $TG_DIR/.env after spawning a coord."
else
  log "routing to coord SID: $COORD_SID"
fi

# --- 4. Write .env ---
cat > "$TG_DIR/.env" <<EOF
TELEGRAM_BOT_TOKEN=$TOKEN
COORDINATOR_SID=$COORD_SID
SWARM_SLUG=$SLUG
WORKER_SOCK=$SWARM_HOME/data/_sock/worker.sock
EOF
chmod 600 "$TG_DIR/.env"
log ".env written (mode 600)"

# --- 5. systemd-user unit ---
UNIT_NAME="bot-swarm-tg-bridge-$SLUG.service"
UNIT_PATH="$HOME/.config/systemd/user/$UNIT_NAME"
mkdir -p "$(dirname "$UNIT_PATH")"

# Optional proxy wrapper (set up by init.sh when TG_PROXY_VIA_XRAY=1)
PROXY_WRAP=""
if [[ -x "$HOME/bin/with-tg-proxy.sh" ]]; then
  PROXY_WRAP="$HOME/bin/with-tg-proxy.sh "
  log "xray proxy wrapper detected; bridge will route through it"
fi

cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Bot-swarm Telegram bridge ($SLUG)
After=network-online.target bot-swarm-worker.service
Wants=bot-swarm-worker.service

[Service]
Type=simple
WorkingDirectory=$TG_DIR
EnvironmentFile=$TG_DIR/.env
ExecStart=${PROXY_WRAP}/usr/bin/python3 $TG_DIR/bridge.py
Restart=on-failure
RestartSec=5
StandardOutput=append:$TG_DIR/bridge.log
StandardError=append:$TG_DIR/bridge.log

[Install]
WantedBy=default.target
EOF
log "wrote $UNIT_PATH"

# --- 6. Enable + start ---
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME" >/dev/null 2>&1 || true
sleep 2
if systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1; then
  log "bridge active ✓"
else
  log "WARN bridge not active. Journal tail:"
  journalctl --user -u "$UNIT_NAME" --no-pager -n 10 2>&1 || true
  exit 1
fi

# --- 7. Quick verification: getMe via the new token, confirms Telegram side ---
log "verifying token with Telegram getMe..."
if [[ -x "$HOME/bin/with-tg-proxy.sh" ]]; then
  GETME="$($HOME/bin/with-tg-proxy.sh curl -sS --max-time 8 "https://api.telegram.org/bot${TOKEN}/getMe")"
else
  GETME="$(curl -sS --max-time 8 "https://api.telegram.org/bot${TOKEN}/getMe")"
fi
if echo "$GETME" | grep -q '"ok":true'; then
  BOT_USERNAME="$(echo "$GETME" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null)"
  log "bot is alive: @${BOT_USERNAME:-unknown}"
else
  log "WARN getMe failed — token may be wrong or Telegram unreachable. Response: $GETME"
fi

cat <<EOF

$LOG_PREFIX bridge for '$SLUG' is up.

  Unit:       $UNIT_NAME
  Bridge log: $TG_DIR/bridge.log
  Edit token: $TG_DIR/.env (mode 600)

  To stop:   systemctl --user stop $UNIT_NAME
  Restart:   systemctl --user restart $UNIT_NAME
  Logs:      journalctl --user -u $UNIT_NAME -f

Forward a message to @${BOT_USERNAME:-the-bot} now — it should land in
coord-side inbox-${COORD_SID}.log within 5 seconds.
EOF
