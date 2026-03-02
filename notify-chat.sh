#!/bin/bash
set -euo pipefail
# notify-chat.sh — Send error notifications to Google Chat webhook.
# Usage:
#   notify-chat.sh <component> <severity> <message>

ENV_FILE="$HOME/.timelapse/.env"
LOG_FILE="$HOME/.timelapse/logs/notify.log"

mkdir -p "$(dirname "$LOG_FILE")"

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

PAYLOAD=$(COMPONENT="$COMPONENT" SEVERITY="$SEVERITY" MESSAGE="$MESSAGE" HOSTNAME="$HOSTNAME" python3 -c 'import json,os
component=os.environ.get("COMPONENT","timelapse")
severity=os.environ.get("SEVERITY","ERROR")
message=os.environ.get("MESSAGE","unknown error")
hostname=os.environ.get("HOSTNAME","unknown-host")
text=f"[{severity}] {component}\\nhost={hostname}\\n{message}"
print(json.dumps({"text": text}, ensure_ascii=False))
')

if curl -sS -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json; charset=UTF-8" \
  -d "$PAYLOAD" \
  --connect-timeout 5 \
  --max-time 10 >/dev/null 2>&1; then
  log "sent component=$COMPONENT severity=$SEVERITY"
else
  log "failed component=$COMPONENT severity=$SEVERITY"
fi
