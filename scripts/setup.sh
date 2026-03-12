#!/bin/bash
set -euo pipefail
# setup.sh — mac-event-collector initial setup
# Idempotent: safe to re-run.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMELAPSE_DIR="$HOME/.timelapse"

echo "=== mac-event-collector setup ==="
echo "repo: $SCRIPT_DIR"
echo "data: $TIMELAPSE_DIR"
echo ""

# ── 1. Create directories
mkdir -p "$TIMELAPSE_DIR/logs"
echo "[1/7] directories OK"

# ── 2. Initialize SQLite DB
if [ ! -f "$TIMELAPSE_DIR/events.db" ]; then
  sqlite3 "$TIMELAPSE_DIR/events.db" < "$SCRIPT_DIR/schema.sql"
  echo "[2/7] events.db created"
else
  sqlite3 "$TIMELAPSE_DIR/events.db" < "$SCRIPT_DIR/schema.sql" 2>/dev/null || true
  echo "[2/7] events.db exists (schema applied)"
fi

# ── 3. Symlink scripts
for name in record-event.sh sync-events.sh notify-chat.sh timelapse-healthcheck.sh; do
  ln -sf "$SCRIPT_DIR/$name" "$TIMELAPSE_DIR/$name"
done
echo "[3/7] scripts symlinked to $TIMELAPSE_DIR/"

# ── 4. sleepwatcher scripts
ln -sf "$SCRIPT_DIR/sleepwatcher/.wakeup" "$HOME/.wakeup"
ln -sf "$SCRIPT_DIR/sleepwatcher/.sleep" "$HOME/.sleep"
echo "[4/7] sleepwatcher scripts symlinked (~/.wakeup, ~/.sleep)"

# ── 5. Check .env
if [ ! -f "$TIMELAPSE_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$TIMELAPSE_DIR/.env"
  echo "[5/7] .env created from template — EDIT ~/.timelapse/.env with your API key!"
else
  echo "[5/7] .env exists (skipped)"
fi

# ── 6. launchd agents
LAUNCH_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"

for PLIST in "$SCRIPT_DIR/launchd/"*.plist; do
  PLIST_NAME=$(basename "$PLIST")
  LABEL=$(echo "$PLIST_NAME" | sed 's/.plist$//')

  # Unload if already loaded
  launchctl list | grep -q "$LABEL" && launchctl unload "$LAUNCH_DIR/$PLIST_NAME" 2>/dev/null || true

  cp "$PLIST" "$LAUNCH_DIR/"
  launchctl load "$LAUNCH_DIR/$PLIST_NAME"
done
echo "[6/7] launchd agents registered"

# ── 7. sleepwatcher
if ! command -v sleepwatcher &>/dev/null; then
  echo "[7/7] WARNING: sleepwatcher not installed. Run: brew install sleepwatcher"
else
  brew services start sleepwatcher 2>/dev/null || true
  echo "[7/7] sleepwatcher started"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit ~/.timelapse/.env (set INGEST_API_KEY)"
echo "  2. Hammerspoon → Reload Config"
echo "  3. Verify: cat ~/.timelapse/logs/record-event.log"
echo "  4. Verify: cat ~/.timelapse/logs/sync.log"
echo ""
echo "Test sleepwatcher:"
echo "  pmset sleepnow  # sleep → wake → check logs"
