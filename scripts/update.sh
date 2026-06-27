#!/usr/bin/env bash
# Update an EXISTING bot-swarm install from the vendored worker in this repo.
#
# init.sh deliberately skips worker extraction when ~/bot-swarm/worker already
# exists (so a re-run doesn't clobber a live install). This script is the
# supported update path: after `git pull` in bot-swarm-init, it rsyncs the new
# worker over the install — never touching data/ or config/ (secrets + runtime
# state) — reinstalls deps, restarts the daemon, health-checks, and auto-rolls
# back if the new worker doesn't come up healthy.
#
# Usage:  cd bot-swarm-init && git pull && ./scripts/update.sh
set -euo pipefail

SWARM_HOME="${SWARM_HOME:-$HOME/bot-swarm}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="$HERE/vendor/bot-swarm.tar.gz"
log() { echo "[swarm-update] $*"; }

[[ -d "$SWARM_HOME/worker" ]] || { log "no install at $SWARM_HOME — run init.sh first"; exit 1; }
[[ -f "$TARBALL" ]]          || { log "missing $TARBALL — did you git pull?"; exit 1; }

# 1. Snapshot the current worker for rollback.
SNAP="$SWARM_HOME/worker.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$SWARM_HOME/worker" "$SNAP"
log "snapshot: $SNAP"

# 2. Extract the new release to a temp dir.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar xzf "$TARBALL" -C "$TMP"

# 3. rsync new worker over the install. Preserve the venv; NEVER touch data/ or
#    config/ (those live under $SWARM_HOME, not under worker/, so they're safe).
rsync -a --delete \
  --exclude='.venv/' --exclude='__pycache__/' --exclude='*.pyc' --exclude='*.egg-info/' \
  "$TMP/worker/" "$SWARM_HOME/worker/"

# Refresh non-secret support trees if the release carries them.
for d in scripts systemd bin templates; do
  [[ -d "$TMP/$d" ]] && rsync -a "$TMP/$d/" "$SWARM_HOME/$d/" || true
done

# 4. Reinstall deps (pyproject may have changed) into the existing venv.
if [[ -x "$SWARM_HOME/worker/.venv/bin/python" ]]; then
  ( cd "$SWARM_HOME/worker" && uv pip install --python .venv/bin/python -e . \
      >/tmp/swarm-update-pip.log 2>&1 ) || log "warn: pip install issues (see /tmp/swarm-update-pip.log)"
fi

# 5. Restart the daemon.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user restart bot-swarm-worker.service 2>/dev/null || true
sleep 4

# 6. Health-check; auto-rollback on failure.
SOCK="$SWARM_HOME/data/_sock/worker.sock"
if curl -sS --unix-socket "$SOCK" --max-time 8 http://w/health 2>/dev/null | grep -q '"ok":true'; then
  log "update OK — worker healthy ($(curl -sS --unix-socket "$SOCK" http://w/health 2>/dev/null))"
  log "keeping snapshot $SNAP (remove when satisfied)"
else
  log "HEALTH CHECK FAILED — rolling back to $SNAP"
  rsync -a --delete --exclude='.venv/' "$SNAP/" "$SWARM_HOME/worker/"
  systemctl --user restart bot-swarm-worker.service 2>/dev/null || true
  log "rolled back. Investigate, then re-run."
  exit 1
fi
