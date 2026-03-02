#!/bin/bash
set -euo pipefail
# record-event.sh — Write an event to the local SQLite store.
# Used by sleepwatcher scripts and can be called from any shell context.
#
# Usage: record-event.sh <event_type> <source> [meta_json]
# Example: record-event.sh device_wake sleepwatcher '{"trigger":"wakeup"}'

DB="$HOME/.timelapse/events.db"
ENV_FILE="$HOME/.timelapse/.env"
LOG_FILE="$HOME/.timelapse/logs/record-event.log"
NOTIFY_SCRIPT="$HOME/.timelapse/notify-chat.sh"

EVENT_TYPE="${1:?Usage: record-event.sh <event_type> <source> [meta_json]}"
SOURCE="${2:?Usage: record-event.sh <event_type> <source> [meta_json]}"
META="${3:-}"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [record] $1" >> "$LOG_FILE"; }
notify_error() {
  local msg="$1"
  if [ -x "$NOTIFY_SCRIPT" ]; then
    "$NOTIFY_SCRIPT" "record-event.sh" "ERROR" "$msg" || true
  fi
}

# ── Load env for SSID mappings
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi
OFFICE_SSIDS="${OFFICE_SSIDS:-}"
HOME_SSIDS="${HOME_SSIDS:-}"

# ── Resolve SSID
SSID=$(/usr/sbin/networksetup -getairportnetwork en0 2>/dev/null | sed 's/^Current Wi-Fi Network: //' || echo "")
if [ -z "$SSID" ] || [ "$SSID" = "You are not associated with an AirPort network." ]; then
  SSID=""
fi

# ── Resolve location from SSID
LOCATION=""
IFS=',' read -ra OFFICE_ARR <<< "$OFFICE_SSIDS"
for s in "${OFFICE_ARR[@]}"; do
  if [ "$s" = "$SSID" ]; then LOCATION="office"; break; fi
done
if [ -z "$LOCATION" ]; then
  IFS=',' read -ra HOME_ARR <<< "$HOME_SSIDS"
  for s in "${HOME_ARR[@]}"; do
    if [ "$s" = "$SSID" ]; then LOCATION="home"; break; fi
  done
fi

# ── Resolve event_at and log_date (JST)
EVENT_AT=$(date "+%Y-%m-%dT%H:%M:%S+09:00")
LOG_DATE=$(date "+%Y-%m-%d")

# home cutoff: events before 4AM at home → previous day
if [ "$LOCATION" = "home" ]; then
  HOUR=$(date "+%H")
  if [ "$HOUR" -lt 4 ]; then
    LOG_DATE=$(date -v-1d "+%Y-%m-%d")
  fi
fi

# ── Add ssid to meta if not already present
if [ -z "$META" ]; then
  META="{\"ssid\":\"$SSID\"}"
elif [ "$SSID" != "" ]; then
  META=$(echo "$META" | sed "s/}$/,\"ssid\":\"$SSID\"}/")
fi

# ── Resolve location SQL value
if [ -z "$LOCATION" ]; then
  LOC_SQL="NULL"
else
  LOCATION_SQL_ESCAPED="${LOCATION//\'/\'\'}"
  LOC_SQL="'$LOCATION_SQL_ESCAPED'"
fi

# ── INSERT OR IGNORE (idempotent)
EVENT_TYPE_SQL_ESCAPED="${EVENT_TYPE//\'/\'\'}"
EVENT_AT_SQL_ESCAPED="${EVENT_AT//\'/\'\'}"
SOURCE_SQL_ESCAPED="${SOURCE//\'/\'\'}"
LOG_DATE_SQL_ESCAPED="${LOG_DATE//\'/\'\'}"
META_SQL_ESCAPED="${META//\'/\'\'}"

if sqlite3 "$DB" "INSERT OR IGNORE INTO events (event_type, event_at, source, location, log_date, meta) VALUES ('$EVENT_TYPE_SQL_ESCAPED', '$EVENT_AT_SQL_ESCAPED', '$SOURCE_SQL_ESCAPED', $LOC_SQL, '$LOG_DATE_SQL_ESCAPED', '$META_SQL_ESCAPED');"; then
  log "OK $SOURCE/$EVENT_TYPE location=$LOCATION ssid=$SSID"
else
  RESULT=$?
  log "ERROR sqlite3 exit=$RESULT $SOURCE/$EVENT_TYPE"
  notify_error "sqlite3 insert failed source=$SOURCE event_type=$EVENT_TYPE exit=$RESULT"
  exit "$RESULT"
fi
