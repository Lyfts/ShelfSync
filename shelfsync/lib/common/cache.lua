local logger = require("shelfsync/lib/common/safe_logger")
local STATUS = require("shelfsync/lib/common/constants/status").STATUS

local Cache = {}
Cache.__index = Cache

function Cache:new(o) return setmetatable(o, self) end

-- Flushes of a provider's queued updates from different reader instances (a
-- closed reader's and the file browser's) run one at a time.
local provider_updates = {}

function Cache:serializeUpdate(callback)
  local key = self.settings.sidecar_key
  if provider_updates[key] then
    table.insert(provider_updates[key], callback)
    return
  end
  local updates = { callback }
  provider_updates[key] = updates
  -- A callback queued behind another returns before it runs. Hold one Wi-Fi
  -- lease around the entire drain.
  self.wifi:withWifi(function(_wifi_enabled, wifi_error)
    for _, update in ipairs(updates) do
      local ok, err = pcall(update, wifi_error)
      if not ok then
        logger.warn(key .. ": could not send update: " .. tostring(err))
      end
    end
    provider_updates[key] = nil
  end)
end

-- Returns whether the provider accepted the new status, which replaces any
-- "finished" still queued for the book (see SyncEngine:flushPendingUpdates).
-- If it's finished too, it's dated when the queued one was finished, which
-- is kept until that date's set too.
function Cache:updateBookStatus(filename, status, ...)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  if not book_id or not self.settings:providerEnabled() then return false end
  local pending = self.settings.pending_updates:get(filename, settings)
  local result = self.provider:updateUserBookFor(settings, status, ...)
  local linked = tostring(self.settings:readBookSetting(filename, "book_id")) == tostring(book_id)
  if linked then
    self.state.book_status = result or {}
  end
  if result and status ~= STATUS.FINISHED then
    if pending then
      self.settings.pending_updates:clearFinished(filename, pending)
    end
    self.settings.pending_updates:clearFinishedElsewhere(filename, book_id)
  end

  if result and status == STATUS.FINISHED then
    local finished_at = pending and pending.finished_at
    if self.provider:onMarkedFinished(book_id, filename, finished_at) and finished_at then
      self.settings.pending_updates:clearFinished(filename, pending)
    end
  end
  return result ~= nil and linked
end

function Cache:cacheUserBook()
  local document = self.ui and self.ui.document
  if not document then
    return nil
  end

  local filename = document.file
  local status, errors = self.api:findUserBook(self.settings:getLinkedBookId(), self.user:getId())
  self.state.book_status = status or {}
  if status and status.page_count and status.page_count > 0 then
    local current_pages = self.settings:readBookSetting(filename, "pages")
    if not current_pages or current_pages == 0 then
      self.settings:updateBookSetting(filename, { pages = status.page_count })
    end
  end
  return errors
end

return Cache
