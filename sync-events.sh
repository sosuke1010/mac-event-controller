#!/bin/bash
set -euo pipefail
# sync-events.sh — Send pending events from SQLite to the Payload CMS API.
# Designed to run via launchd timer every 3 minutes.

DB="$HOME/.timelapse/events.db"
ENV_FILE="$HOME/.timelapse/.env"
LOG_FILE="$HOME/.timelapse/logs/sync.log"
LOCK_FILE="$HOME/.timelapse/sync.lock"
BATCH_SIZE_DEFAULT=50
MAX_RETRIES=20
NOTIFY_SCRIPT="$HOME/.timelapse/notify-chat.sh"
DRY_RUN="${SYNC_DRY_RUN:-0}"
BATCH_SIZE="$BATCH_SIZE_DEFAULT"
TMP_BODY_FILE="$(mktemp /tmp/timelapse_sync_body.XXXXXX)"

cleanup() {
  rm -f "$TMP_BODY_FILE"
}
trap cleanup EXIT

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --limit=*)
      BATCH_SIZE="${arg#*=}"
      ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [sync] $1" >> "$LOG_FILE"; }
notify_error() {
  local msg="$1"
  if [ -x "$NOTIFY_SCRIPT" ]; then
    "$NOTIFY_SCRIPT" "sync-events.sh" "ERROR" "$msg" || true
  fi
}

# ── flock: prevent concurrent runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "SKIP already running"
  exit 0
fi

# ── Load env
if [ ! -f "$ENV_FILE" ]; then
  log "ERROR .env not found at $ENV_FILE"
  notify_error ".env not found at $ENV_FILE"
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

if [ ! -f "$DB" ]; then
  log "ERROR events.db not found at $DB"
  notify_error "events.db not found at $DB"
  exit 1
fi

if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [ "$BATCH_SIZE" -le 0 ]; then
  log "ERROR invalid batch size: $BATCH_SIZE"
  notify_error "invalid batch size: $BATCH_SIZE"
  exit 1
fi

API_BASE="${INGEST_API_BASE_URL:-}"
API_KEY="${INGEST_API_KEY:-}"
if [ -z "$API_BASE" ] || [ -z "$API_KEY" ]; then
  log "ERROR INGEST_API_BASE_URL or INGEST_API_KEY is missing"
  notify_error "INGEST_API_BASE_URL or INGEST_API_KEY is missing"
  exit 1
fi

ENDPOINT="${API_BASE}/api/ingest/raw-events"

# ── Fetch pending events
ROWS=$(sqlite3 -json "$DB" "SELECT id, event_type, event_at, source, location, log_date, meta FROM events WHERE synced_at IS NULL AND retry_count < $MAX_RETRIES ORDER BY id ASC LIMIT $BATCH_SIZE;" 2>/dev/null || echo "[]")

COUNT=$(echo "$ROWS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$COUNT" = "0" ]; then
  log "OK 0 pending"
  exit 0
fi

log "START pending=$COUNT batch_size=$BATCH_SIZE dry_run=$DRY_RUN endpoint=$API_BASE"

SENT=0
FAILED=0
NOW=$(date "+%Y-%m-%d %H:%M:%S")

if [ "$DRY_RUN" = "1" ]; then
  PREVIEW=$(echo "$ROWS" | python3 -c "import sys,json; rows=json.load(sys.stdin); print(','.join(str(r.get('id')) for r in rows[:10]))")
  log "DRY_RUN ids=$PREVIEW"
  exit 0
fi

while IFS= read -r line; do
  ID=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  PAYLOAD=$(echo "$line" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['payload']))")

  HTTP_CODE=$(curl -s -o "$TMP_BODY_FILE" -w "%{http_code}" \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "X-Ingest-Key: $API_KEY" \
    -d "$PAYLOAD" \
    --connect-timeout 5 \
    --max-time 15 \
    2>/dev/null || echo "000")

  BODY="$(<"$TMP_BODY_FILE")"

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    sqlite3 "$DB" "UPDATE events SET synced_at = '$NOW', last_attempt_at = '$NOW' WHERE id = $ID;"
    SENT=$((SENT + 1))
    log "OK id=$ID http=$HTTP_CODE"
  else
    ERROR_MSG="http=$HTTP_CODE body=${BODY:0:200}"
    ERROR_MSG_SQL_ESCAPED="${ERROR_MSG//\'/\'\'}"
    sqlite3 "$DB" "UPDATE events SET retry_count = retry_count + 1, last_error = '$ERROR_MSG_SQL_ESCAPED', last_attempt_at = '$NOW' WHERE id = $ID;"
    RETRY_COUNT=$(sqlite3 "$DB" "SELECT retry_count FROM events WHERE id = $ID;" 2>/dev/null || echo "unknown")
    FAILED=$((FAILED + 1))
    log "FAIL id=$ID http=$HTTP_CODE retry_count=$RETRY_COUNT endpoint=$API_BASE"
    notify_error "sync failed id=$ID http=$HTTP_CODE retry_count=$RETRY_COUNT endpoint=$API_BASE"
  fi
done < <(echo "$ROWS" | python3 -c "
import sys, json

rows = json.load(sys.stdin)
for row in rows:
    meta = row.get('meta') or '{}'
    try:
        meta_obj = json.loads(meta)
    except:
        meta_obj = {}

    payload = {
        'source': row['source'],
        'event_type': row['event_type'],
        'event_at': row['event_at'],
        'log_date': row['log_date'],
    }
    if row.get('location'):
        payload['location'] = row['location']
    if meta_obj:
        payload['meta'] = meta_obj

    print(json.dumps({'id': row['id'], 'payload': payload}))
")

log "DONE sent=$SENT failed=$FAILED"
if [ "$FAILED" -gt 0 ]; then
  notify_error "sync completed with failures sent=$SENT failed=$FAILED endpoint=$API_BASE"
fi
