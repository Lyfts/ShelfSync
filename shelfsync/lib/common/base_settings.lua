-- Shared settings logic for all sync providers (StoryGraph, Hardcover, ...).
--
-- Provider-specific settings classes (storygraph_settings.lua, hardcover_settings.lua)
-- extend this via metatable inheritance:
--
--   local HardcoverSettings = setmetatable({}, { __index = BaseSettings })
--   HardcoverSettings.__index = HardcoverSettings
--   function HardcoverSettings:new(path, ui, shared)
--     return BaseSettings.new(self, path, ui, "hardcover", shared)
--   end
--
-- `sidecar_key` is the per-provider sub-table name used to store book links
-- inside a document's sidecar (metadata.lua) file, so a single book can be
-- linked to more than one provider independently.
--
-- `shared` is another BaseSettings instance (the StoryGraph settings, in
-- practice) that SHARED_KEYS below are transparently redirected to, so
-- settings like tracking mode or verbose logging are combined across
-- providers instead of being configured twice. If omitted, an instance is
-- its own `shared` (i.e. it owns those keys itself).
local KoreaderVersion = require("version")
local LuaSettings = require("luasettings")
local DocSettings = require("docsettings")
local logger = require("logger")

local _t = require("shelfsync/lib/common/table_util")
local SETTING = require("shelfsync/lib/common/constants/settings")

local BaseSettings = {}
BaseSettings.__index = BaseSettings

-- Settings that are combined across all providers instead of being kept
-- independently per service (see shelfsync/lib/common/menu.lua, which is the
-- only place these are surfaced in the UI). Any instance other than `shared`
-- itself transparently redirects reads/writes of these keys to `shared`.
local SHARED_KEYS = {
  [SETTING.ENABLE_WIFI] = true,
  [SETTING.MENU_CONFIRMATION] = true,
  [SETTING.COMPATIBILITY_MODE] = true,
  [SETTING.INCLUDE_LOCATION_IN_NOTES] = true,
  [SETTING.VERBOSE_LOGGING] = true,
  [SETTING.SYNC_BY_REMOTE_PAGES] = true,
  [SETTING.ALWAYS_SYNC] = true,
  [SETTING.SYNC_ON_OPEN] = true,
  [SETTING.TRACK_METHOD] = true,
  [SETTING.TRACK_FREQUENCY] = true,
  [SETTING.TRACK_PERCENTAGE] = true,
  [SETTING.TRACK_PAGE_STEP] = true,
  [SETTING.LINK_BY_ISBN] = true,
  [SETTING.LINK_BY_TITLE] = true,
}

function BaseSettings:new(path, ui, sidecar_key, shared)
  local o = {}
  setmetatable(o, self)

  o.settings = LuaSettings:open(path)
  o.ui = ui
  o.sidecar_key = sidecar_key
  o.subscribers = {}
  o.shared = shared or o

  if KoreaderVersion:getNormalizedCurrentVersion() < 202403010000 then
    if o:readSetting(SETTING.COMPATIBILITY_MODE) == nil then
      o:updateSetting(SETTING.COMPATIBILITY_MODE, true)
    end
  end

  return o
end

function BaseSettings:getDocSettings(filename)
  if self.ui and self.ui.doc_settings and self.ui.document and self.ui.document.file == filename then
    return self.ui.doc_settings
  end
  return DocSettings:open(filename)
end

function BaseSettings:readSetting(key)
  if SHARED_KEYS[key] and self.shared ~= self then
    return self.shared:readSetting(key)
  end
  return self.settings:readSetting(key)
end

function BaseSettings:readBookSettings(filename)
  if not filename then
    return {}
  end

  -- 1. Try sidecar first (provider sub-table in metadata.lua)
  local sidecar = self:getDocSettings(filename)
  local sidecar_data = sidecar:readSetting(self.sidecar_key)
  if sidecar_data then
    return sidecar_data
  end

  -- 2. Fallback to global books table
  local books = self.settings:readSetting("books")
  if books and books[filename] then
    return books[filename]
  end

  return {}
end

function BaseSettings:readBookSetting(filename, key)
  if not filename then
    return
  end

  local settings = self:readBookSettings(filename)
  if settings then
    return settings[key]
  end
end

function BaseSettings:updateBookSetting(filename, config)
  if not filename then return end

  -- 1. Load existing data (prioritizing sidecar)
  local book_setting = self:readBookSettings(filename)
  local original_value = {}
  for k, v in pairs(book_setting) do original_value[k] = v end

  -- 2. Apply changes
  for k, v in pairs(config) do
    if k == "_delete" then
      for _, name in ipairs(v) do
        book_setting[name] = nil
      end
    else
      book_setting[k] = v
    end
  end

  -- 3. Save to sidecar
  local sidecar = self:getDocSettings(filename)
  sidecar:saveSetting(self.sidecar_key, book_setting)
  sidecar:flush()

  -- 4. Clean up global table (Migration)
  local books = self.settings:readSetting("books")
  if books and books[filename] then
    books[filename] = nil
    self.settings:saveSetting("books", books)
    self.settings:flush()
  end

  self:notify(SETTING.BOOKS, { filename = filename, config = config }, original_value)
end

function BaseSettings:updateSetting(key, value)
  if SHARED_KEYS[key] and self.shared ~= self then
    return self.shared:updateSetting(key, value)
  end

  local original_value = self.settings:readSetting(key)
  self.settings:saveSetting(key, value)

  self.settings:flush()

  self:notify(key, value, original_value)
end

function BaseSettings:notify(key, value, original_value)
  for _, cb in ipairs(self.subscribers) do
    cb(key, value, original_value)
  end
end

function BaseSettings:subscribe(cb)
  table.insert(self.subscribers, cb)
end

function BaseSettings:unsubscribe(cb)
  local new_subscribers = {}
  for _, original_cb in ipairs(self.subscribers) do
    if original_cb ~= cb then
      table.insert(new_subscribers, original_cb)
    end
  end
  self.subscribers = new_subscribers
end

function BaseSettings:setSync(value)
  self:updateBookSetting(self.ui.document.file, { sync = value == true })
end

function BaseSettings:setTrackMethod(method)
  self:updateSetting(SETTING.TRACK_METHOD, method)
end

function BaseSettings:bookLinked()
  return self:getLinkedBookId() ~= nil
end

function BaseSettings:getFilePath()
  return _t.dig(self, "ui", "document", "file")
end

function BaseSettings:getLinkedTitle()
  return self:readBookSetting(self:getFilePath(), "title")
end

function BaseSettings:getLinkedEditionFormat()
  return self:readBookSetting(self:getFilePath(), "edition_format")
end

function BaseSettings:fileSyncEnabled(file)
  if not file then
    return false
  end

  local sync_value = self:readBookSetting(file, "sync")
  if sync_value == nil then
    sync_value = self:readSetting(SETTING.ALWAYS_SYNC)
  end
  return sync_value ~= false
end

function BaseSettings:syncEnabled()
  return self:fileSyncEnabled(self:getFilePath())
end

function BaseSettings:autolinkEnabled()
  for _, setting in ipairs(SETTING.AUTOLINK_OPTIONS) do
    -- Must go through self:readSetting (not self.settings:readSetting)
    -- since LINK_BY_ISBN/LINK_BY_TITLE are SHARED_KEYS: StoryGraph's
    -- settings file is where they're actually stored, so reading straight
    -- off this instance's own settings would always miss them for every
    -- non-StoryGraph provider, silently disabling autolink for those.
    if self:readSetting(setting) then
      return true
    end
  end

  return false
end

function BaseSettings:pages()
  return self:readBookSetting(self:getFilePath(), "pages")
end

function BaseSettings:trackFrequency()
  return self:readSetting(SETTING.TRACK_FREQUENCY) or 5
end

function BaseSettings:trackPercentageInterval()
  return self:readSetting(SETTING.TRACK_PERCENTAGE) or 10
end

function BaseSettings:trackMethod()
  return self:readSetting(SETTING.TRACK_METHOD) or SETTING.TRACK.FREQUENCY
end

function BaseSettings:trackByTime()
  local setting = self:readSetting(SETTING.TRACK_METHOD)
  return setting == nil or setting == SETTING.TRACK.FREQUENCY
end

function BaseSettings:trackByProgress()
  local method = self:readSetting(SETTING.TRACK_METHOD)
  -- Fallback if pages tracking is selected but remote page count is missing
  if method == SETTING.TRACK.PAGES then
    local pages = self:pages()
    if not pages or pages <= 0 then
      return true
    end
  end
  return method == SETTING.TRACK.PROGRESS
end

function BaseSettings:changeTrackPercentageInterval(percent)
  self:updateSetting(SETTING.TRACK_PERCENTAGE, percent)
end

function BaseSettings:compatibilityMode()
  return self:readSetting(SETTING.COMPATIBILITY_MODE) == true
end

function BaseSettings:setMenuConfirm(status)
  self:updateSetting(SETTING.MENU_CONFIRMATION, status)
end

function BaseSettings:menuConfirm()
  return self:readSetting(SETTING.MENU_CONFIRMATION) == true
end

function BaseSettings:syncByRemotePages()
  return self:readSetting(SETTING.SYNC_BY_REMOTE_PAGES) == true
end

function BaseSettings:syncOnOpen()
  return self:readSetting(SETTING.SYNC_ON_OPEN) == true
end

function BaseSettings:verboseLogging()
  return self:readSetting(SETTING.VERBOSE_LOGGING) == true
end

-- Easy way to add logging that only shows up with "Verbose logging" enabled
-- in settings, without every call site checking the setting itself:
--   self.settings:debugLog("StoryGraph: some detail =", value)
--   self.settings:debugWarn("StoryGraph: unexpected thing happened")
function BaseSettings:debugLog(...)
  if self:verboseLogging() then
    logger.info(...)
  end
end

function BaseSettings:debugWarn(...)
  if self:verboseLogging() then
    logger.warn(...)
  end
end

function BaseSettings:trackByPages()
  local pages = self:pages()
  return self:readSetting(SETTING.TRACK_METHOD) == SETTING.TRACK.PAGES and (pages and pages > 0)
end

function BaseSettings:trackPageStep()
  return self:readSetting(SETTING.TRACK_PAGE_STEP) or 10
end

return BaseSettings
