#!/bin/bash
# timelapse-healthcheck.sh
#
# Hammerspoon timelapse モジュールの外部ヘルスチェック。
# launchd agent から5分ごとに実行される。
#
# 判定ロジック:
#   1. heartbeat ファイルが stale (>5分未更新) → hs.reload() を実行
#   2. 直近5分以内に reload 済みなら skip（連打ガード）
#   3. reload 後に heartbeat が更新されたか確認（成功判定）
#   4. hs CLI 実行失敗時は exit code と stderr を明示ログ化

STATE_DIR="$HOME/.hammerspoon/timelapse-state"
HEARTBEAT="$HOME/.timelapse/heartbeat"
LAST_RELOAD="$STATE_DIR/last_reload"
HEALTHCHECK_LOG="$STATE_DIR/healthcheck.log"
NOTIFY_SCRIPT="$HOME/.timelapse/notify-chat.sh"
STALE_THRESHOLD=300      # heartbeat が stale とみなす秒数 (5分)
RELOAD_COOLDOWN=300      # reload 連打ガード秒数 (5分)
VERIFY_WAIT=15           # reload 後の heartbeat 更新確認待ち秒数

TAG="[healthcheck]"
NOW=$(date +%s)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

log() {
  echo "$TIMESTAMP $TAG $1" >> "$HEALTHCHECK_LOG"
}

notify_error() {
  local msg="$1"
  if [ -x "$NOTIFY_SCRIPT" ]; then
    "$NOTIFY_SCRIPT" "timelapse-healthcheck.sh" "ERROR" "$msg" || true
  fi
}

notify_warning() {
  local msg="$1"
  if [ -x "$NOTIFY_SCRIPT" ]; then
    "$NOTIFY_SCRIPT" "timelapse-healthcheck.sh" "WARNING" "$msg" || true
  fi
}

is_transient_ipc_error() {
  local text="$1"
  case "$text" in
    *"message port was invalidated"*|*"transport errors are normal if Hammerspoon is reloading"*|*"dropping corrupt reply Mach message"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ── state dir がなければ作成
mkdir -p "$STATE_DIR"

# ── hs CLI を探す
HS_CLI="/usr/local/bin/hs"
if [ ! -x "$HS_CLI" ]; then
  HS_CLI="/opt/homebrew/bin/hs"
fi
if [ ! -x "$HS_CLI" ]; then
  log "ERROR hs CLI not found at /usr/local/bin/hs or /opt/homebrew/bin/hs"
  notify_error "hs CLI not found at /usr/local/bin/hs or /opt/homebrew/bin/hs"
  exit 1
fi

# ── heartbeat 確認
if [ ! -f "$HEARTBEAT" ]; then
  log "STALE heartbeat file not found"
  STALE=true
else
  LAST_BEAT=$(cat "$HEARTBEAT" 2>/dev/null || echo "0")
  AGE=$((NOW - LAST_BEAT))
  if [ "$AGE" -gt "$STALE_THRESHOLD" ]; then
    log "STALE heartbeat age=${AGE}s (threshold=${STALE_THRESHOLD}s)"
    STALE=true
  else
    log "OK heartbeat fresh age=${AGE}s"
    STALE=false
  fi
fi

if [ "$STALE" = "false" ]; then
  exit 0
fi

# ── reload 連打ガード
if [ -f "$LAST_RELOAD" ]; then
  LAST_RELOAD_AT=$(cat "$LAST_RELOAD" 2>/dev/null || echo "0")
  SINCE_RELOAD=$((NOW - LAST_RELOAD_AT))
  if [ "$SINCE_RELOAD" -lt "$RELOAD_COOLDOWN" ]; then
    log "SKIP reload cooldown (last reload ${SINCE_RELOAD}s ago, cooldown=${RELOAD_COOLDOWN}s)"
    exit 0
  fi
fi

# ── reload 実行
log "RELOAD executing hs.reload()"
echo "$NOW" > "$LAST_RELOAD"

HS_OUTPUT=$("$HS_CLI" -c "hs.reload()" 2>&1)
HS_EXIT=$?

if [ "$HS_EXIT" -ne 0 ]; then
  if is_transient_ipc_error "$HS_OUTPUT"; then
    log "WARNING transient hs.reload() failure exit_code=${HS_EXIT} output=${HS_OUTPUT}"
    notify_warning "transient hs.reload() failure exit_code=${HS_EXIT} output=${HS_OUTPUT}"
    exit 0
  fi
  log "ERROR hs.reload() failed exit_code=${HS_EXIT} output=${HS_OUTPUT}"
  notify_error "hs.reload() failed exit_code=${HS_EXIT} output=${HS_OUTPUT}"
  exit 1
fi

log "RELOAD hs.reload() sent exit_code=${HS_EXIT}"

# ── 成功判定: heartbeat が更新されるか確認
sleep "$VERIFY_WAIT"

if [ -f "$HEARTBEAT" ]; then
  NEW_BEAT=$(cat "$HEARTBEAT" 2>/dev/null || echo "0")
  if [ "$NEW_BEAT" -gt "$NOW" ]; then
    log "VERIFIED heartbeat updated after reload (new=${NEW_BEAT})"
  else
    log "WARNING heartbeat NOT updated after reload (old=${NEW_BEAT}, reload_at=${NOW})"
    notify_error "heartbeat not updated after reload old=${NEW_BEAT} reload_at=${NOW}"
  fi
else
  log "WARNING heartbeat file still missing after reload"
  notify_error "heartbeat file still missing after reload"
fi
