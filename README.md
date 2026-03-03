# mac-event-collector

macOS 上のシステムイベント（wake/sleep/power/wifi）を収集し、SQLite にローカル保存 → Payload CMS REST API にバッチ送信するシステム。

## Architecture

```
[sleepwatcher]  ──→  SQLite  ←──  [Hammerspoon]
                      │
                [sync-events.sh]  (launchd, 3min)
                      │
                      ▼
              [Payload CMS API]
```

- **sleepwatcher**: カーネルレベル (IOKit) で wake/sleep を検知。最も信頼性が高い
- **Hammerspoon**: power/wifi/app イベントを検知。`hs.sqlite3` が使える場合は直接書き込み、使えない場合は `record-event.sh` にフォールバック
- **sync-events.sh**: 未送信イベントを API にバッチ送信。検知とは完全に分離

## Setup

```bash
# 前提: Homebrew, Hammerspoon (IPC enabled)
brew install sleepwatcher sqlite3

git clone git@github.com:sosuke1010/mac-event-collector.git ~/mac-event-collector
cd ~/mac-event-collector
./scripts/setup.sh

# 環境変数を設定
vi ~/.timelapse/.env

# Hammerspoon 設定のリンク (init.lua から require)
# → hammerspoon/timelapse.lua を参照
```

## Environment Variables (`~/.timelapse/.env`)

| Variable | Description | Example |
|---|---|---|
| `INGEST_API_BASE_URL` | Payload CMS base URL | `https://cms.sosuke.page` |
| `INGEST_API_KEY` | Ingest auth key | (secret) |
| `GOOGLE_CHAT_WEBHOOK_URL` | Google Chat incoming webhook URL (optional) | `https://chat.googleapis.com/v1/spaces/...` |
| `GOOGLE_CHAT_NOTIFY_COOLDOWN_SEC` | 同一エラー通知の抑制秒数 | `600` |
| `OFFICE_SSIDS` | Office WiFi SSIDs (comma-separated) | `ALC_7CE7,biz-tenjincho` |
| `HOME_SSIDS` | Home WiFi SSIDs (comma-separated) | `Buffalo-3DC0-WPA3` |
| `HOME_LOG_DATE_CUTOFF_HOUR` | 自宅時の log_date 前日繰り上げ閾値 | `4` |

## Config Priority

1. `hammerspoon/timelapse.lua` のデフォルト値
2. `~/.timelapse/.env`（通常はこちらを編集）
3. `~/.hammerspoon/timelapse_config.lua`（存在する場合のみ最終上書き）

`timelapse_config.lua` は必須ではありません。運用上は `.env` を正として扱います。

## Data Flow

```
Event detected → SQLite INSERT OR IGNORE
                   → synced_at = NULL
                   → sync-events.sh picks up
                   → curl POST to API
                   → synced_at = timestamp (on success)
                   → retry_count++ (on failure, max 20)
```

## Monitoring

```bash
# Event recording log
tail -f ~/.timelapse/logs/record-event.log

# Sync log
tail -f ~/.timelapse/logs/sync.log

# Pending events count
sqlite3 ~/.timelapse/events.db "SELECT COUNT(*) FROM events WHERE synced_at IS NULL AND retry_count < 20;"

# Hammerspoon heartbeat
cat ~/.timelapse/heartbeat

# Healthcheck log
tail -f ~/.hammerspoon/timelapse-state/healthcheck.log

# launchd agents status
launchctl list | grep timelapse
```

## sync-events.sh manual test

```bash
# dry-run (送信なし、対象idだけ確認)
~/.timelapse/sync-events.sh --dry-run --limit=10

# 1件だけ送信
~/.timelapse/sync-events.sh --limit=1

# 通常実行
~/.timelapse/sync-events.sh
```

補足:
- API 側で `sleepwatcher` source を受理できるため、`sync-events.sh` は source を変換せず DB の値をそのまま送信します。

## sleepwatcher 実機検証 (pmset sleepnow)

1. 事前にログ監視を開始
   - `tail -f ~/.timelapse/logs/record-event.log`
2. スリープ実行
   - `pmset sleepnow`
3. 手動で復帰 (蓋を開く/キー入力)
4. 以下が確認できれば合格
   - `record-event.log` に `sleepwatcher/device_sleep` と `sleepwatcher/device_wake`
   - DB に `event_type=device_sleep` と `event_type=device_wake`

DB確認コマンド:

```bash
sqlite3 ~/.timelapse/events.db "SELECT id,event_type,source,event_at,location,synced_at,retry_count,last_error FROM events ORDER BY id DESC LIMIT 20;"
```

## 完了条件 (Definition of Done)

- Hammerspoon が `.env` を読み、`timelapse_config.lua` 不在でも起動する
- `hs.sqlite3` が無い環境でもフォールバック経由でイベントが記録される
- `sync-events.sh` の失敗時に `retry_count` / `last_error` / `last_attempt_at` が更新される
- `pmset sleepnow` テストで sleep/wake 両イベントが確認できる
- エラー時に Google Chat 通知が送信される

## GUIでのチェック項目（あなたが操作）

- Hammerspoon
  - `Reload Config`
  - Console で `env loaded`, watcher started, sqlite mode (`hs.sqlite3` or fallback) を確認
- macOS 実操作
  - Wi-Fi ON/OFF または AP 切替で `wifi_connect/disconnect`
  - 電源抜き差しで `power_connect/disconnect`
  - `pmset sleepnow` 後に wake で `device_sleep/device_wake`
- launchd
  - `com.timelapse.sync`, `com.timelapse.healthcheck` がロード済み
- Google Chat
  - テスト用の失敗通知を 1 件受信

## 共有してほしいログ（テンプレ）

- Hammerspoon Console（起動〜イベント1回分）
- `~/.timelapse/logs/record-event.log` 最新30行
- `~/.timelapse/logs/sync.log` 最新50行
- `~/.hammerspoon/timelapse-state/healthcheck.log` 最新50行
- DBクエリ結果
  - `SELECT COUNT(*) FROM events WHERE synced_at IS NULL AND retry_count < 20;`
  - `SELECT id,event_type,source,event_at,location,synced_at,retry_count,last_error FROM events ORDER BY id DESC LIMIT 20;`
- Google Chat の通知スクリーンショット（失敗系1件）

## Related Repositories

- [my-handbook](https://github.com/sosuke1010/my-handbook) — Payload CMS (API: `/api/ingest/raw-events`)
- [door-ble-logger](https://github.com/sosuke1010/door-ble-logger) — mini PC BLE door sensor
