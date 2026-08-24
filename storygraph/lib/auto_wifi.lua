local SETTING = require("storygraph/lib/constants/settings")

local Device = require("device")

local NetworkMgr = require("ui/network/manager")

local AutoWifi = {
  connection_pending = false
}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

function AutoWifi:withWifi(callback)
  if NetworkMgr:isWifiOn() then
    self.settings:debugLog("StoryGraph: withWifi - wifi already on, calling back immediately")
    callback(false)
    return
  end

  local enable_wifi_setting = self.settings:readSetting(SETTING.ENABLE_WIFI)
  local has_wifi_restore = Device:hasWifiRestore()
  local not_airplane_mode = G_reader_settings:nilOrFalse("airplanemode")
  if enable_wifi_setting
      and not NetworkMgr.pending_connection
      and has_wifi_restore
      and not_airplane_mode then

    self.settings:debugLog("StoryGraph: withWifi - wifi off, restoring automatically")
    local original_on = NetworkMgr.wifi_was_on

    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      -- restore original "was on" state to prevent wifi being restored automatically after suspend
      NetworkMgr.wifi_was_on = original_on
      G_reader_settings:saveSetting("wifi_was_on", original_on)

      self.connection_pending = false

      self.settings:debugLog("StoryGraph: withWifi - connectivity check finished, wifi_on=" .. tostring(NetworkMgr:isWifiOn()))
      callback(true)

      -- TODO: schedule turn off wifi, debounce
      self:wifiDisableSilent()
    end)
  else
    -- Auto-connect is unavailable or disabled: don't leave callers hanging,
    -- let them handle the "still not connected" case themselves (e.g. retry).
    self.settings:debugLog("StoryGraph: withWifi - wifi off, not auto-restoring - enable_wifi_setting="
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

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    NetworkMgr:turnOnWifiAndWaitForConnection(network_callback)
  else
    NetworkMgr:promptWifiOn(network_callback)
  end
end

function AutoWifi:wifiDisablePrompt()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) and Device:hasWifiRestore() then
    self:wifiDisableSilent()
  else
    NetworkMgr:toggleWifiOff()
  end
end

return AutoWifi
