---@diagnostic disable: redundant-parameter
local SETTING = require("shelfsync/lib/common/constants/settings")

local Device = require("device")

local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local AutoWifi = {}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

-- NetworkMgr is shared by all providers, so the restore and the period during
-- which the plugin owns Wi-Fi must also be shared. Keep a lease for each
-- operation until its callback has actually returned. In particular, Trapper
-- callbacks can yield while an HTTP subprocess is still running.
local active_wifi_session = nil
local CONNECTIVITY_TIMEOUT = 46 -- KOReader gives up after roughly 45 seconds.
local ONLINE_CHECK_INTERVAL = 1

local function cancelConnectTimeout(session)
  if session.connect_timeout then
    UIManager:unschedule(session.connect_timeout)
    session.connect_timeout = nil
  end
end

local function cancelOnlineCheck(session)
  if session.online_check then
    UIManager:unschedule(session.online_check)
    session.online_check = nil
  end
end

local function finishSessionIfIdle(session)
  if active_wifi_session ~= session
      or session.pending
      or session.dispatching
      or session.active_operations > 0
      or session.closing then
    return
  end

  session.closing = true
  session.owner:wifiDisableSilent(function()
    if active_wifi_session ~= session then return end
    active_wifi_session = nil

    -- A request that arrived while the radio was being shut down starts a
    -- fresh restore after the shutdown callback completes.
    local queued = session.after_close or {}
    for _, request in ipairs(queued) do
      request.owner:withWifi(request.callback)
    end
  end)
end

local function invokeWithWifi(callback, wifi_enabled, session, wifi_error)
  if session then
    session.active_operations = session.active_operations + 1
  end

  local released = false
  local function release()
    if released then return end
    released = true
    if session then
      session.active_operations = session.active_operations - 1
      finishSessionIfIdle(session)
    end
  end

  local function runCallback()
    -- Trapper:wrap already catches and logs errors. The inner xpcall makes
    -- sure the Wi-Fi lease is released before that error is rethrown.
    local ok, err = xpcall(function()
      callback(wifi_enabled, wifi_error)
    end, debug.traceback)
    release()
    if not ok then error(err) end
  end

  if Trapper.isWrapped and Trapper:isWrapped() then
    runCallback()
  else
    Trapper:wrap(runCallback)
  end
end

local function dispatchQueued(session, wifi_enabled)
  local callbacks = session.callbacks
  session.callbacks = {}
  session.dispatching = true
  for _, request in ipairs(callbacks) do
    invokeWithWifi(request.callback, wifi_enabled, session)
  end
  session.dispatching = false
  finishSessionIfIdle(session)
end

local function failRestore(session, reason)
  if active_wifi_session ~= session or session.connected then return end
  cancelConnectTimeout(session)
  cancelOnlineCheck(session)
  session.pending = false
  session.closing = true
  local callbacks = session.callbacks
  session.callbacks = {}

  session.owner.settings:debugWarn(session.owner.label .. ": withWifi - connectivity restore failed: " .. tostring(reason))
  for _, request in ipairs(callbacks) do
    invokeWithWifi(request.callback, false, nil, reason)
  end

  -- A restore that never becomes usable should not leave the radio on. Keep
  -- this session active until shutdown finishes so new callers queue instead
  -- of mistaking the half-connected interface for a usable connection.
  session.owner:wifiDisableSilent(function()
    if active_wifi_session ~= session then return end
    active_wifi_session = nil

    local queued = session.after_close or {}
    for _, request in ipairs(queued) do
      request.owner:withWifi(request.callback)
    end
  end)
end

local function isOnline()
  -- isConnected() only establishes that the interface has an address. The
  -- on-demand restore can reach that point before DHCP/DNS is ready, so wait
  -- for KOReader's online check when it is available.
  if type(NetworkMgr.isOnline) == "function" then
    local ok, online = pcall(NetworkMgr.isOnline, NetworkMgr)
    return ok and online or false
  end
  return NetworkMgr:isConnected()
end

local function finishRestore(session)
  if active_wifi_session ~= session or session.connected or session.closing then return end
  cancelConnectTimeout(session)
  cancelOnlineCheck(session)
  session.pending = false
  session.connected = true

  -- Restore the original "was on" state to prevent Wi-Fi being restored
  -- automatically after suspend.
  NetworkMgr.wifi_was_on = session.original_on
  G_reader_settings:saveSetting("wifi_was_on", session.original_on)

  session.owner.settings:debugLog(session.owner.label .. ": withWifi - online check finished, wifi_on=" .. tostring(NetworkMgr:isWifiOn())
    .. " queued_callbacks=" .. #session.callbacks)
  dispatchQueued(session, true)
end

local function checkOnline(session)
  if active_wifi_session ~= session or session.closing or session.connected then return end
  if isOnline() then
    finishRestore(session)
    return
  end

  session.online_check = function()
    session.online_check = nil
    checkOnline(session)
  end
  UIManager:scheduleIn(ONLINE_CHECK_INTERVAL, session.online_check)
end

function AutoWifi:withWifi(callback)
  local session = active_wifi_session
  if session then
    if session.closing then
      self.settings:debugLog(self.label .. ": withWifi - wifi shutdown in progress, queuing")
      session.after_close = session.after_close or {}
      table.insert(session.after_close, { owner = self, callback = callback })
    elseif session.connected then
      self.settings:debugLog(self.label .. ": withWifi - reusing active wifi session")
      invokeWithWifi(callback, true, session)
    else
      self.settings:debugLog(self.label .. ": withWifi - restore already in flight, queuing")
      table.insert(session.callbacks, { owner = self, callback = callback })
    end
    return
  end

  if NetworkMgr:isWifiOn() then
    self.settings:debugLog(self.label .. ": withWifi - wifi already on, calling back immediately")
    invokeWithWifi(callback, false, nil)
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
    session = {
      owner = self,
      callbacks = { { owner = self, callback = callback } },
      after_close = {},
      active_operations = 0,
      original_on = NetworkMgr.wifi_was_on,
      pending = true,
      connected = false,
      associated = false,
      dispatching = false,
      closing = false,
    }
    active_wifi_session = session

    session.connect_timeout = function()
      failRestore(session, "timed out")
    end
    UIManager:scheduleIn(CONNECTIVITY_TIMEOUT, session.connect_timeout)

    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      if active_wifi_session ~= session or session.associated or session.closing then return end
      session.associated = true
      self.settings:debugLog(self.label .. ": withWifi - interface connected, waiting for network readiness")
      checkOnline(session)
    end)
  else
    -- Auto-connect is unavailable or disabled: don't leave callers hanging,
    -- let them handle the "still not connected" case themselves (e.g. retry).
    self.settings:debugLog(self.label .. ": withWifi - wifi off, not auto-restoring - enable_wifi_setting="
      .. tostring(enable_wifi_setting) .. " pending_connection=" .. tostring(NetworkMgr.pending_connection)
      .. " has_wifi_restore=" .. tostring(has_wifi_restore) .. " not_airplane_mode=" .. tostring(not_airplane_mode))
    invokeWithWifi(callback, false, nil)
  end
end

-- Whether Wi-Fi is on because withWifi turned it on, until it's turned off
-- again, so NetworkConnected is from that rather than the user.
function AutoWifi:turnedWifiOn()
  return active_wifi_session ~= nil
end

function AutoWifi:wifiDisableSilent(callback)
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
    if callback then callback() end
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
