local M = {}
M.VERSION = "2026-03-02.2"

local home = os.getenv("HOME") or ""
local dbPath = home .. "/.timelapse/events.db"
local envPath = home .. "/.timelapse/.env"
local configPath = home .. "/.hammerspoon/timelapse_config.lua"
local heartbeatPath = home .. "/.timelapse/heartbeat"
local recordEventScriptPath = home .. "/.timelapse/record-event.sh"
local notifyScriptPath = home .. "/.timelapse/notify-chat.sh"
local TAG = "[timelapse]"

local defaultConfig = {
  officeSSIDs = { "Office-WiFi" },
  homeSSIDs = { "Home-WiFi" },
  homeLogDateCutoffHour = 4,
}

local cfg = nil
local watcher = nil
local batteryWatcher = nil
local wifiWatcher = nil
local healthTimer = nil
local lastPowerSource = nil
local lastSSID = nil
local lastActivityEpoch = 0

local sqlite3 = nil
local sqlite3Available = false
local fallbackWarningSent = false

local function nowEpoch()
  return os.time()
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitCSV(value)
  local out = {}
  if not value or value == "" then
    return out
  end
  for part in value:gmatch("([^,]+)") do
    local item = trim(part)
    if item ~= "" then
      table.insert(out, item)
    end
  end
  return out
end

local function notifyError(message)
  if hs.fs.attributes(notifyScriptPath, "mode") ~= "file" then
    return
  end
  local task = hs.task.new("/bin/bash", nil, {
    notifyScriptPath,
    "timelapse.lua",
    "ERROR",
    tostring(message),
  })
  if task then
    task:start()
  end
end

local function loadEnvFile(path)
  local result = {}
  local file = io.open(path, "r")
  if not file then
    return result, false
  end

  for line in file:lines() do
    local trimmed = trim(line)
    if trimmed ~= "" and not trimmed:match("^#") then
      local key, value = trimmed:match("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
      if key then
        local parsed = trim(value or "")
        if (parsed:sub(1, 1) == "\"" and parsed:sub(-1) == "\"")
          or (parsed:sub(1, 1) == "'" and parsed:sub(-1) == "'") then
          parsed = parsed:sub(2, -2)
        end
        result[key] = parsed
      end
    end
  end
  file:close()
  return result, true
end

-- ─────────────────────────────────────── context & location

local function tableContains(arr, value)
  if not value then return false end
  for _, v in ipairs(arr or {}) do
    if v == value then return true end
  end
  return false
end

local function getSSID()
  local ssid = hs.wifi.currentNetwork()
  if ssid then return ssid end
  local output = hs.execute("/usr/sbin/networksetup -getairportnetwork en0 2>/dev/null", false)
  if output then
    local name = output:match("Current Wi%-Fi Network:%s*(.+)")
    if name then return name:gsub("%s+$", "") end
  end
  return nil
end

local function resolveLocation(ssid)
  if tableContains(cfg.officeSSIDs, ssid) then return "office" end
  if tableContains(cfg.homeSSIDs, ssid) then return "home" end
  return nil
end

local function resolveLogDate(location)
  local t = os.date("*t")
  local logDate = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
  if location == "home" and t.hour < (cfg.homeLogDateCutoffHour or 4) then
    local prev = os.date("*t", os.time({
      year = t.year, month = t.month, day = t.day, hour = 12, min = 0, sec = 0,
    }) - 86400)
    logDate = string.format("%04d-%02d-%02d", prev.year, prev.month, prev.day)
  end
  return logDate
end

local function nowISO()
  local t = os.date("*t")
  return string.format("%04d-%02d-%02dT%02d:%02d:%02d+09:00",
    t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- ─────────────────────────────────────── event write

local function recordEventViaScript(eventType, ssid, extraMeta, reason)
  local meta = {}
  if extraMeta then
    for k, v in pairs(extraMeta) do
      meta[k] = v
    end
  end
  if ssid and ssid ~= "" then
    meta.ssid = ssid
  end
  local metaJson = hs.json.encode(meta) or "{}"

  local task = hs.task.new("/bin/bash", function(exitCode, stdOut, stdErr)
    if exitCode == 0 then
      print(TAG .. " fallback enqueue: " .. eventType .. " reason=" .. tostring(reason))
    else
      local detail = "fallback failed event=" .. eventType
        .. " exit=" .. tostring(exitCode)
        .. " stderr=" .. tostring(stdErr or "")
      print(TAG .. " ERROR " .. detail)
      notifyError(detail)
    end
  end, {
    recordEventScriptPath,
    eventType,
    "hammerspoon",
    metaJson,
  })

  if not task or not task:start() then
    local detail = "cannot start fallback script: " .. recordEventScriptPath
    print(TAG .. " ERROR " .. detail)
    notifyError(detail)
  end
end

local function recordEventViaSqlite(eventType, ssid, extraMeta)
  local location = resolveLocation(ssid)
  local logDate = resolveLogDate(location)
  local eventAt = nowISO()

  local meta = {}
  if ssid and ssid ~= "" then
    meta.ssid = ssid
  end
  if extraMeta then
    for k, v in pairs(extraMeta) do
      meta[k] = v
    end
  end
  local metaJson = hs.json.encode(meta) or "{}"

  local ok, err = pcall(function()
    local db = sqlite3.open(dbPath)
    db:exec("PRAGMA journal_mode=WAL")
    local stmt = db:prepare([[
      INSERT OR IGNORE INTO events (event_type, event_at, source, location, log_date, meta)
      VALUES (?, ?, 'hammerspoon', ?, ?, ?)
    ]])
    if stmt then
      stmt:bind_values(eventType, eventAt, location, logDate, metaJson)
      stmt:step()
      stmt:finalize()
    end
    db:close()
  end)

  if ok then
    print(TAG .. " enqueue: " .. eventType .. " logDate=" .. logDate .. " location=" .. tostring(location) .. " event_at=" .. eventAt)
    return true
  end

  local detail = "sqlite write failed event=" .. eventType .. " err=" .. tostring(err)
  print(TAG .. " ERROR " .. detail)
  notifyError(detail)
  return false
end

local function recordEvent(eventType, ssid, extraMeta)
  if sqlite3Available then
    local ok = recordEventViaSqlite(eventType, ssid, extraMeta)
    if ok then
      return
    end
    recordEventViaScript(eventType, ssid, extraMeta, "sqlite_error")
    return
  end

  if not fallbackWarningSent then
    fallbackWarningSent = true
    local warn = "hs.sqlite3 unavailable; fallback to record-event.sh"
    print(TAG .. " WARNING " .. warn)
    notifyError(warn)
  end
  recordEventViaScript(eventType, ssid, extraMeta, "sqlite_unavailable")
end

-- ─────────────────────────────────────── heartbeat

local function writeHeartbeat()
  local file = io.open(heartbeatPath, "w")
  if file then file:write(tostring(nowEpoch())); file:close() end
end

-- ─────────────────────────────────────── event handlers

local function onWakeLike(trigger)
  local eventType = ({
    systemDidWake    = "device_wake",
    screensDidUnlock = "screen_unlock",
    screensDidWake   = "screen_wake",
  })[trigger] or ("wake_" .. trigger)

  lastActivityEpoch = nowEpoch()
  local ssid = getSSID()
  print("")
  print(TAG .. " -- " .. eventType .. " [" .. trigger .. "] ssid=" .. tostring(ssid))
  recordEvent(eventType, ssid)
end

local function onSleep()
  lastActivityEpoch = nowEpoch()
  local ssid = getSSID()
  print("")
  print(TAG .. " -- device_sleep ssid=" .. tostring(ssid))
  recordEvent("device_sleep", ssid)
end

local function onPowerChange()
  local source = hs.battery.powerSource()
  if source == lastPowerSource then return end
  local eventType = (source == "AC Power") and "power_connect" or "power_disconnect"
  lastPowerSource = source
  lastActivityEpoch = nowEpoch()

  local ssid = getSSID()
  print("")
  print(TAG .. " -- " .. eventType .. " source=" .. tostring(source) .. " ssid=" .. tostring(ssid))
  recordEvent(eventType, ssid, { power_source = source })
end

local function onWifiChange()
  local ssid = getSSID()
  if ssid == lastSSID then return end
  local prevSSID = lastSSID
  lastSSID = ssid
  lastActivityEpoch = nowEpoch()

  print("")
  if ssid then
    print(TAG .. " -- wifi_connect ssid=" .. tostring(ssid) .. " prev=" .. tostring(prevSSID))
    recordEvent("wifi_connect", ssid, { prev_ssid = prevSSID })
  else
    print(TAG .. " -- wifi_disconnect prev=" .. tostring(prevSSID))
    recordEvent("wifi_disconnect", nil, { prev_ssid = prevSSID })
  end
end

-- ─────────────────────────────────────── config

local function loadConfig()
  local envValues, envLoaded = loadEnvFile(envPath)

  cfg = hs.fnutils.copy(defaultConfig)
  if envLoaded then
    local office = splitCSV(envValues.OFFICE_SSIDS or "")
    local homeSSIDs = splitCSV(envValues.HOME_SSIDS or "")
    local cutoff = tonumber(envValues.HOME_LOG_DATE_CUTOFF_HOUR or "")
    if #office > 0 then
      cfg.officeSSIDs = office
    end
    if #homeSSIDs > 0 then
      cfg.homeSSIDs = homeSSIDs
    end
    if cutoff then
      cfg.homeLogDateCutoffHour = cutoff
    end
    print(TAG .. " env loaded from " .. envPath)
  else
    print(TAG .. " WARNING: .env not found at " .. envPath .. " (default config only)")
  end

  if hs.fs.attributes(configPath, "mode") == "file" then
    local ok, loaded = pcall(dofile, configPath)
    if ok and type(loaded) == "table" then
      for k, v in pairs(loaded) do
        cfg[k] = v
      end
      print(TAG .. " config override loaded from " .. configPath)
    else
      print(TAG .. " ERROR: config override load failed at " .. configPath)
      notifyError("timelapse_config.lua load failed")
    end
  else
    print(TAG .. " config override not found (optional): " .. configPath)
  end

  print(TAG .. " officeSSIDs=" .. hs.json.encode(cfg.officeSSIDs))
  print(TAG .. " homeSSIDs=" .. hs.json.encode(cfg.homeSSIDs))
  print(TAG .. " homeLogDateCutoffHour=" .. tostring(cfg.homeLogDateCutoffHour))
end

-- ─────────────────────────────────────── M.start()

function M.start()
  print("")
  print("============================================================")
  print(TAG .. " v" .. M.VERSION .. "  |  " .. os.date("%Y-%m-%d %H:%M:%S"))
  print("============================================================")

  math.randomseed(os.time())

  local sqliteOk, sqliteModule = pcall(require, "hs.sqlite3")
  if sqliteOk then
    sqlite3 = sqliteModule
    sqlite3Available = true
    print(TAG .. " sqlite mode=hs.sqlite3")
  else
    sqlite3 = nil
    sqlite3Available = false
    print(TAG .. " WARNING sqlite mode=fallback (hs.sqlite3 unavailable)")
  end

  loadConfig()

  if hs.location.servicesEnabled() then
    hs.location.start()
    print(TAG .. " location services started")
  end

  local ssid = getSSID()
  print(TAG .. " current SSID=" .. tostring(ssid))
  print(TAG .. " db=" .. dbPath)

  if watcher then watcher:stop() end
  watcher = hs.caffeinate.watcher.new(function(eventType)
    if eventType == hs.caffeinate.watcher.systemDidWake then
      onWakeLike("systemDidWake")
    elseif eventType == hs.caffeinate.watcher.screensDidUnlock then
      onWakeLike("screensDidUnlock")
    elseif eventType == hs.caffeinate.watcher.screensDidWake then
      onWakeLike("screensDidWake")
    elseif eventType == hs.caffeinate.watcher.systemWillSleep then
      onSleep()
    end
  end)
  watcher:start()
  print(TAG .. " watcher started (Wake/Sleep/Unlock/ScreenWake)")

  lastPowerSource = hs.battery.powerSource()
  if batteryWatcher then batteryWatcher:stop() end
  batteryWatcher = hs.battery.watcher.new(onPowerChange)
  batteryWatcher:start()
  print(TAG .. " watcher started (Power: " .. tostring(lastPowerSource) .. ")")

  lastSSID = getSSID()
  if wifiWatcher then wifiWatcher:stop() end
  wifiWatcher = hs.wifi.watcher.new(onWifiChange)
  wifiWatcher:start()
  print(TAG .. " watcher started (WiFi)")

  lastActivityEpoch = nowEpoch()
  writeHeartbeat()
  if healthTimer then healthTimer:stop() end
  healthTimer = hs.timer.doEvery(60, function()
    writeHeartbeat()
    lastActivityEpoch = nowEpoch()
  end)

  recordEvent("app_start", getSSID())

  print(TAG .. " ready")
end

return M
