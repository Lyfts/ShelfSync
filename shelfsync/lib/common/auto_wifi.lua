local SETTING = require("shelfsync/lib/common/constants/settings")

local Device = require("device")

local NetworkMgr = require("ui/network/manager")

local AutoWifi = {}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

-- Module-level (not per-instance): StoryGraph and Hardcover each get their
-- own AutoWifi, but there's only one real NetworkMgr, so a restore kicked
-- off by one engine must be visible to the other. Without this, a second
-- withWifi() call arriving while a restore is in flight would see
-- NetworkMgr:isWifiOn() already true (the wifi interface comes up ~instantly,
-- well before the actual network association/DHCP completes -- see
-- restoreWifiAsync) and wrongly treat that as "already connected", firing
-- its callback immediately against a connection that doesn't functionally
-- exist yet. Queuing onto the same in-flight restore instead means every
-- caller's callback only fires once real connectivity is confirmed, and
-- wifi only gets auto-disabled once afterward, no matter how many engines
-- asked for it around the same time.
local pending_restore = nil -- nil, or { callbacks = { ... }, original_on = <bool> }

function AutoWifi:withWifi(callback)
  if pending_restore then
    self.settings:debugLog(self.label .. ": withWifi - restore already in flight, queuing")
    table.insert(pending_restore.callbacks, callback)
    return
  end

  if NetworkMgr:isWifiOn() then
    self.settings:debugLog(self.label .. ": withWifi - wifi already on, calling back immediately")
    callback(false)
    return
  end

  local enable_wifi_setting = self.settings:readSetting(SETTING.SHARED.ENABLE_WIFI)
  local has_wifi_restore = Device:hasWifiRestore()
  local not_airplane_mode = G_reader_settings:nilOrFalse("airplanemode")
  if enable_wifi_setting
      and not NetworkMgr.pending_connection
      and has_wifi_restore
      and not_airplane_mode then

    self.settings:debugLog(self.label .. ": withWifi - wifi off, restoring automatically")
    pending_restore = { callbacks = { callback }, original_on = NetworkMgr.wifi_was_on }

    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      local restore = pending_restore
      pending_restore = nil

      -- restore original "was on" state to prevent wifi being restored automatically after suspend
      NetworkMgr.wifi_was_on = restore.original_on
      G_reader_settings:saveSetting("wifi_was_on", restore.original_on)

      self.settings:debugLog(self.label .. ": withWifi - connectivity check finished, wifi_on=" .. tostring(NetworkMgr:isWifiOn())
        .. " queued_callbacks=" .. #restore.callbacks)
      for _, queued_callback in ipairs(restore.callbacks) do
        queued_callback(true)
      end

      -- TODO: schedule turn off wifi, debounce
      self:wifiDisableSilent()
    end)
  else
    -- Auto-connect is unavailable or disabled: don't leave callers hanging,
    -- let them handle the "still not connected" case themselves (e.g. retry).
    self.settings:debugLog(self.label .. ": withWifi - wifi off, not auto-restoring - enable_wifi_setting="
      .. tostring(enable_wifi_setting) .. " pending_connection=" .. tostring(NetworkMgr.pending_connection)
      .. " has_wifi_restore=" .. tostring(has_wifi_restore) .. " not_airplane_mode=" .. tostring(not_airplane_mode))
    callback(false)
  end
end

function AutoWifi:wifiDisableSilent()
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
  end)
end

function AutoWifi:wifiPrompt(callback)
  if NetworkMgr:isWifiOn() then
    if callback then
      callback(false)
    end

    return
  end

  if G_reader_settings:isTrue("airplanemode") then
    return
  end

  local network_callback = callback and function() callback(true) end or nil

  if self.settings:readSetting(SETTING.SHARED.ENABLE_WIFI) then
    NetworkMgr:turnOnWifiAndWaitForConnection(network_callback)
  else
    NetworkMgr:promptWifiOn(network_callback)
  end
end

function AutoWifi:wifiDisablePrompt()
  if self.settings:readSetting(SETTING.SHARED.ENABLE_WIFI) and Device:hasWifiRestore() then
    self:wifiDisableSilent()
  else
    NetworkMgr:toggleWifiOff()
  end
end

return AutoWifi
