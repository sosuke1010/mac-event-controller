#!/bin/bash
set -euo pipefail
# notify-chat.sh — Send error notifications to Google Chat webhook.
# Usage:
#   notify-chat.sh <component> <severity> <message>

ENV_FILE="$HOME/.timelapse/.env"
LOG_FILE="$HOME/.timelapse/logs/notify.log"
STATE_DIR="$HOME/.timelapse/notify-state"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [notify] $1" >> "$LOG_FILE"
}

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

WEBHOOK_URL="${GOOGLE_CHAT_WEBHOOK_URL:-}"
if [ -z "$WEBHOOK_URL" ]; then
  exit 0
fi

COMPONENT="${1:-timelapse}"
SEVERITY="${2:-ERROR}"
MESSAGE="${3:-unknown error}"
HOSTNAME="$(scutil --get LocalHostName 2>/dev/null || hostname)"
EVENT_TS="$(date '+%Y-%m-%d %H:%M:%S')"
NOW_EPOCH="$(date +%s)"
COOLDOWN_SEC="${GOOGLE_CHAT_NOTIFY_COOLDOWN_SEC:-0}"

SIGNATURE=$(printf "%s" "${COMPONENT}|${SEVERITY}|${MESSAGE}" | shasum -a 256 | awk '{print $1}')
STAMP_FILE="$STATE_DIR/${SIGNATURE}.ts"

if [[ "$COOLDOWN_SEC" =~ ^[0-9]+$ ]] && [ "$COOLDOWN_SEC" -gt 0 ] && [ -f "$STAMP_FILE" ]; then
  LAST_SENT="$(<"$STAMP_FILE")"
  if [[ "$LAST_SENT" =~ ^[0-9]+$ ]]; then
    ELAPSED=$((NOW_EPOCH - LAST_SENT))
    if [ "$ELAPSED" -lt "$COOLDOWN_SEC" ]; then
      log "skip cooldown component=$COMPONENT severity=$SEVERITY elapsed=${ELAPSED}s"
      exit 0
    fi
  fi
fi

PAYLOAD=$(COMPONENT="$COMPONENT" SEVERITY="$SEVERITY" MESSAGE="$MESSAGE" HOSTNAME="$HOSTNAME" EVENT_TS="$EVENT_TS" python3 -c 'import json,os
component=os.environ.get("COMPONENT","timelapse")
severity=os.environ.get("SEVERITY","ERROR")
message=os.environ.get("MESSAGE","unknown error")
hostname=os.environ.get("HOSTNAME","unknown-host")
event_ts=os.environ.get("EVENT_TS","unknown-time")
text=f"[{severity}][{event_ts}] {component}\\nhost={hostname}\\n{message}"
print(json.dumps({"text": text}, ensure_ascii=False))
')

if curl -sS -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json; charset=UTF-8" \
  -d "$PAYLOAD" \
  --connect-timeout 5 \
  --max-time 10 >/dev/null 2>&1; then
  echo "$NOW_EPOCH" > "$STAMP_FILE"
  log "sent component=$COMPONENT severity=$SEVERITY"
else
  log "failed component=$COMPONENT severity=$SEVERITY"
fi
