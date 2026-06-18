#!/usr/bin/env bash
# swarm — attach to (or create) the coord tmux session running Claude Code.
#
# Usage:
#   swarm             # attach if 'coord' exists; otherwise create + auto-load /swarm-up
#   swarm <name>      # use a different tmux session name (default: 'coord')
#   swarm --new       # force a fresh session (rejects an existing 'coord')
#   swarm --status    # one-line status of the session; don't attach
#
# Daily use: just `swarm`. From inside Claude, type `/exit` (or `Ctrl-b d` to
# just detach) to leave the session running in the background; next `swarm`
# attaches you back to the same session with full conversation history.

set -euo pipefail

SESSION="${SWARM_TMUX_SESSION:-coord}"
MODE="attach"
for arg in "$@"; do
  case "$arg" in
    --new)     MODE="new" ;;
    --status)  MODE="status" ;;
    --help|-h) sed -n '1,20p' "$0"; exit 0 ;;
    *)         SESSION="$arg" ;;
  esac
done

session_exists() { tmux has-session -t "$SESSION" 2>/dev/null; }

case "$MODE" in
  status)
    if session_exists; then
      echo "session '$SESSION' is running"
      tmux list-windows -t "$SESSION" -F '  window #{window_index}: #{window_name}  [#{window_panes} pane(s)]' 2>/dev/null
    else
      echo "no session '$SESSION'"
    fi
    exit 0
    ;;
  new)
    if session_exists; then
      echo "session '$SESSION' already exists. Use plain 'swarm' to attach, or pick another name." >&2
      exit 1
    fi
    ;;
esac

if ! command -v tmux >/dev/null 2>&1; then
  echo "swarm: tmux not installed. Run init.sh (or apt install tmux) first." >&2
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "swarm: claude not on PATH. Run init.sh (or source ~/.bash_profile) first." >&2
  exit 1
fi

# Inside an existing tmux client → use switch-client so we don't nest.
# Outside tmux → attach normally.
attach_cmd() {
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "$SESSION"
  else
    exec tmux attach -t "$SESSION"
  fi
}

if session_exists; then
  attach_cmd
fi

# Fresh session — create detached with a plain login shell as the session
# command. If we ran `claude` directly as tmux's child and claude exited
# (auth fail, TTY issue, anything), tmux would close the session
# immediately. Wrapping in bash means the session persists even if claude
# bails; user lands on a shell prompt instead of a dead session.
tmux new -d -s "$SESSION" "bash -l"
# Let the shell come up before sending keys.
sleep 0.4
tmux send-keys -t "$SESSION" "claude" Enter
# Give claude a moment to come up before the REPL is ready for input.
sleep 1.8
tmux send-keys -t "$SESSION" "/swarm-up" Enter
attach_cmd
