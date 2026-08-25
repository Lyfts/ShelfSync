-- Minimal but faithful mocks of the KOReader modules plugin code requires,
-- wired into package.loaded so require() picks them up. Lets specs run the
-- REAL plugin source (sync_engine.lua, business.lua, auto_wifi.lua,
-- base_settings.lua, scheduler.lua, ...) under a fake event loop that mimics
-- UIManager's scheduling semantics closely enough to reproduce
-- timing/ordering-dependent behavior (e.g. the wifi-restore race between the
-- StoryGraph and Hardcover engines) that pure static analysis can't verify.
--
-- Usage: require this module once per spec file (it wires package.loaded as
-- a side effect), then call `mocks.reset()` in `before_each` to get a clean
-- clock/queue/network state between tests.

table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
table.unpack = table.unpack or unpack

local LOG = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  table.insert(LOG, line)
end

----------------------------------------------------------------------
-- Fake clock + UIManager event loop (mirrors real scheduling semantics:
-- a time-sorted task queue, scheduleIn computes an absolute time, ties
-- preserve insertion order, nextTick == scheduleIn(0)).
----------------------------------------------------------------------
local Clock = { now = 0 }

local UIManager = {}
UIManager._task_queue = {} -- list of {time=, action=, args=}

local function insertSorted(q, task)
  -- Mirrors real UIManager: descending time order, earliest at the end.
  local lo, hi = 1, #q
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if q[mid].time <= task.time then hi = mid - 1 else lo = mid + 1 end
  end
  table.insert(q, lo, task)
end

function UIManager:scheduleIn(seconds, action, ...)
  local task = { time = Clock.now + seconds, action = action, args = table.pack(...) }
  insertSorted(self._task_queue, task)
end

function UIManager:nextTick(action, ...)
  self:scheduleIn(0, action, ...)
end

function UIManager:unschedule(action)
  for i = #self._task_queue, 1, -1 do
    if self._task_queue[i].action == action then
      table.remove(self._task_queue, i)
    end
  end
end

function UIManager:show(...) end

function UIManager:close(...) end

function UIManager:forceRePaint() end

local listeners = {}
function UIManager:broadcastEvent(event)
  for _, fn in ipairs(listeners) do fn(event) end
end

function UIManager._addListener(fn) table.insert(listeners, fn) end

-- Drains the queue, advancing the fake clock to each task's scheduled time
-- (so delays are respected but the test doesn't actually sleep).
function UIManager:_runUntilIdle(max_steps)
  max_steps = max_steps or 100000
  local steps = 0
  while #UIManager._task_queue > 0 and steps < max_steps do
    steps = steps + 1
    local task = table.remove(UIManager._task_queue) -- last = earliest
    Clock.now = math.max(Clock.now, task.time)
    task.action(table.unpack(task.args))
  end
end

package.loaded["ui/uimanager"] = UIManager

----------------------------------------------------------------------
-- Trivial modules
----------------------------------------------------------------------
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["logger"] = {
  info = function(...) log("[info]", ...) end,
  warn = function(...) log("[warn]", ...) end,
  err = function(...) log("[err]", ...) end,
  dbg = function(...) end,
}
package.loaded["util"] = {
  splitFilePathName = function(f) return "/dir/", "file.epub" end,
  splitFileNameSuffix = function(f) return "file", "epub" end,
}
package.loaded["ui/event"] = { new = function(_, name) return { name = name } end }
package.loaded["ui/event"].__index = package.loaded["ui/event"]
setmetatable(package.loaded["ui/event"], { __call = function() end })
package.loaded["ui/widget/notification"] = { new = function(_, o) return o end }
package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) return o end }
package.loaded["version"] = { getNormalizedCurrentVersion = function() return 202501010000 end }
package.loaded["device"] = { hasWifiRestore = function() return true end }
package.loaded["ui/time"] = {
  s = function(sec) return sec end,
  now = function() return Clock.now end,
}

_G.G_reader_settings = {
  nilOrFalse = function(_, k) return true end,
  isTrue = function(_, k) return false end,
  saveSetting = function() end,
}

----------------------------------------------------------------------
-- Fake Trapper: real one runs the func via a coroutine + xpcall, catching
-- errors. Test functions never yield, so a plain xpcall is faithful enough
-- while still catching runtime errors like the real one does. Set
-- TRAPPER_RAISE=1 to let errors propagate raw (with traceback) for debugging
-- instead of being swallowed and merely logged.
----------------------------------------------------------------------
package.loaded["ui/trapper"] = {
  wrap = function(_self, func)
    if os.getenv("TRAPPER_RAISE") then
      return func()
    end
    local ok, err = xpcall(func, debug.traceback)
    if not ok then
      log("[trapper] error in wrapped function:", err)
    end
  end,
}

----------------------------------------------------------------------
-- Fake NetworkMgr: models isWifiOn() flipping true the instant the restore
-- "script" is kicked off (as sysfsWifiOn does on Kobo -- interface up, not
-- yet actually connected), and isConnected()/the connectivity check only
-- succeeding after CONNECT_DELAY seconds.
----------------------------------------------------------------------
local CONNECT_DELAY = 2 -- seconds for a simulated real wifi association

local NetworkMgr = {
  _wifi_on = false,
  _connected = false,
  pending_connection = false,
  wifi_was_on = false,
}

function NetworkMgr:isWifiOn() return self._wifi_on end

function NetworkMgr:isConnected() return self._connected end

function NetworkMgr:restoreWifiAsync()
  log("[NetworkMgr] restoreWifiAsync() called at t=" .. Clock.now)
  -- Interface comes up ~instantly (this is the key real-world behavior:
  -- sysfsWifiOn on Kobo just checks the interface directory exists).
  self._wifi_on = true
  -- Actual association/DHCP takes real time.
  UIManager:scheduleIn(CONNECT_DELAY, function()
    self._connected = true
    log("[NetworkMgr] actually connected at t=" .. Clock.now)
  end)
end

function NetworkMgr:scheduleConnectivityCheck(callback)
  local function check(iter)
    if self._wifi_on and self._connected then
      log("[NetworkMgr] connectivity check succeeded at t=" .. Clock.now .. " (iter=" .. iter .. ")")
      UIManager:broadcastEvent({ name = "NetworkConnected" })
      callback(true)
    else
      UIManager:scheduleIn(0.25, check, iter + 1)
    end
  end
  UIManager:scheduleIn(0.25, check, 1)
end

function NetworkMgr:turnOffWifi(cb) if cb then cb() end end

package.loaded["ui/network/manager"] = NetworkMgr

----------------------------------------------------------------------
-- Trivial network/serialization stubs: only needed so that requiring
-- api.lua modules (hardcover/api.lua, storygraph/api.lua) doesn't blow up
-- at load time on their top-level `require`s. Specs that only exercise pure
-- data-transformation functions (e.g. normalizedEdition) never call into
-- these, so they don't need real behavior.
----------------------------------------------------------------------
package.loaded["socket.http"] = package.loaded["socket.http"] or {}
package.loaded["ltn12"] = package.loaded["ltn12"] or { sink = { table = function() end } }
package.loaded["json"] = package.loaded["json"] or { encode = function() end, decode = function() end }
package.loaded["ffi/util"] = package.loaded["ffi/util"] or { template = function(s) return s end }
package.loaded["socketutil"] = package.loaded["socketutil"] or {}

----------------------------------------------------------------------
-- Fake docsettings/luasettings: simple in-memory per-path key/value stores,
-- faithful enough to base_settings.lua's usage (readSetting/saveSetting/
-- flush). Keyed by path so `open()` for the same path returns the same
-- store, mirroring real KOReader's caching.
----------------------------------------------------------------------
local function makeStore()
  local data = {}
  return {
    readSetting = function(_, k) return data[k] end,
    saveSetting = function(_, k, v) data[k] = v end,
    flush = function() end,
    _data = data,
  }
end

local doc_settings_stores = {}
package.loaded["docsettings"] = {
  open = function(_, filename)
    doc_settings_stores[filename] = doc_settings_stores[filename] or makeStore()
    return doc_settings_stores[filename]
  end,
}

local plugin_settings_stores = {}
package.loaded["luasettings"] = {
  open = function(_, path)
    plugin_settings_stores[path] = plugin_settings_stores[path] or makeStore()
    return plugin_settings_stores[path]
  end,
}

----------------------------------------------------------------------
-- Reset helper for use in before_each: clears the clock, task queue,
-- network state, and settings stores, without re-wiring package.loaded
-- (which would break any module-level `local X = require(...)` upvalues
-- already captured by previously-required plugin code).
----------------------------------------------------------------------
local function reset()
  Clock.now = 0
  UIManager._task_queue = {}
  NetworkMgr._wifi_on = false
  NetworkMgr._connected = false
  NetworkMgr.pending_connection = false
  NetworkMgr.wifi_was_on = false
  for k in pairs(doc_settings_stores) do doc_settings_stores[k] = nil end
  for k in pairs(plugin_settings_stores) do plugin_settings_stores[k] = nil end
  for i = #LOG, 1, -1 do LOG[i] = nil end
end

return {
  log = log,
  LOG = LOG,
  Clock = Clock,
  UIManager = UIManager,
  NetworkMgr = NetworkMgr,
  CONNECT_DELAY = CONNECT_DELAY,
  makeStore = makeStore,
  reset = reset,
}
