#!/bin/bash
set -euo pipefail
# deploy.sh — Deploy updates after git pull.
#
# Scripts are symlinked to the repo, so git pull automatically updates them.
# This script handles the parts that need explicit action:
#   - Ensure symlinks exist
#   - Apply schema migrations
#   - Sync launchd plists (reload only if changed)
#   - Sync sleepwatcher scripts
#   - Reload Hammerspoon

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMELAPSE_DIR="$HOME/.timelapse"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
skip() { echo -e "  ${YELLOW}–${NC} $1 (skip)"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

echo "=== deploy ($(date '+%H:%M:%S')) ==="
echo "repo: $REPO_DIR"
echo ""

# ─── 1. Directories
mkdir -p "$TIMELAPSE_DIR/logs" "$LAUNCH_DIR"
ok "directories"

# ─── 2. Symlinks: ~/.timelapse/*.sh → repo
SCRIPTS=(record-event.sh sync-events.sh notify-chat.sh timelapse-healthcheck.sh)
changed_scripts=0

for name in "${SCRIPTS[@]}"; do
  src="$REPO_DIR/$name"
  dst="$TIMELAPSE_DIR/$name"

  if [ ! -f "$src" ]; then
    warn "$name not found in repo"
    continue
  fi

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    continue
  fi

  ln -sf "$src" "$dst"
  changed_scripts=$((changed_scripts + 1))
done

if [ "$changed_scripts" -gt 0 ]; then
  ok "symlinks ($changed_scripts updated)"
else
  ok "symlinks (all current)"
fi

# ─── 3. Sleepwatcher scripts
for name in .wakeup .sleep; do
  src="$REPO_DIR/sleepwatcher/$name"
  dst="$HOME/$name"

  if [ ! -f "$src" ]; then continue; fi

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    continue
  fi

  ln -sf "$src" "$dst"
done
ok "sleepwatcher (~/.wakeup, ~/.sleep)"

# ─── 4. SQLite schema
if [ -f "$TIMELAPSE_DIR/events.db" ]; then
  sqlite3 "$TIMELAPSE_DIR/events.db" < "$REPO_DIR/schema.sql" 2>/dev/null || true
  ok "schema applied"
else
  sqlite3 "$TIMELAPSE_DIR/events.db" < "$REPO_DIR/schema.sql"
  ok "events.db created"
fi

# ─── 5. launchd plists (reload only if content changed)
reloaded=0

for plist in "$REPO_DIR/launchd/"*.plist; do
  [ -f "$plist" ] || continue
  name=$(basename "$plist")
  label="${name%.plist}"
  dst="$LAUNCH_DIR/$name"

  if [ -f "$dst" ] && diff -q "$plist" "$dst" >/dev/null 2>&1; then
    continue
  fi

  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  cp "$plist" "$dst"
  launchctl bootstrap "gui/$(id -u)" "$dst" 2>/dev/null \
    || launchctl load "$dst" 2>/dev/null || true
  reloaded=$((reloaded + 1))
done

if [ "$reloaded" -gt 0 ]; then
  ok "launchd ($reloaded plist reloaded)"
else
  ok "launchd (no changes)"
fi

# ─── 6. Hammerspoon reload
# hs.reload() restarts Hammerspoon, which kills the IPC connection before the
# CLI can receive a response. Fire-and-forget with a background kill timer.
if command -v hs >/dev/null 2>&1; then
  hs -c "hs.reload()" >/dev/null 2>&1 &
  hs_pid=$!
  ( sleep 3 && kill "$hs_pid" 2>/dev/null ) &
  wait "$hs_pid" 2>/dev/null || true
  ok "hammerspoon reloaded"
else
  warn "hs CLI not found — reload Hammerspoon manually"
fi

echo ""
echo -e "${GREEN}=== deploy complete ===${NC}"
