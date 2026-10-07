local logger = require("shelfsync/lib/common/safe_logger")
local STATUS = require("shelfsync/lib/common/constants/status").STATUS

local Cache = {}
Cache.__index = Cache

function Cache:new(o) return setmetatable(o, self) end

-- Live, queued and manual writes share an order across reader instances.
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
  -- lease around the entire drain, including when a manual status starts it.
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

-- Returns whether the provider accepted the new status. Once a finished
-- status has been, one still queued for the book is sent with it, dated
-- when that was finished, and kept until the date's set too (see
-- SyncEngine:flushPendingUpdates). Another status doesn't replace it here,
-- as Hardcover's visibility change also sends the status the book already
-- has; queueBookStatus does that for a status chosen in the menus.
function Cache:updateBookStatus(filename, status, ...)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  if not book_id or not self.settings:providerEnabled() then return false end
  local pending = status == STATUS.FINISHED and self.settings.pending_updates:get(filename, settings)
  local result = self.provider:updateUserBookFor(settings, status, ...)
  local linked = tostring(self.settings:readBookSetting(filename, "book_id")) == tostring(book_id)
  if linked then
    self.state.book_status = result or {}
    self.state.locally_finished_book_id = result and status == STATUS.FINISHED
      and result.status_id == STATUS.FINISHED and tostring(book_id) or nil
  end

  if result and status == STATUS.FINISHED then
    local finished_at = pending and pending.finished_at
    if self.provider:onMarkedFinished(book_id, filename, finished_at) and finished_at then
      self.settings.pending_updates:clearFinished(filename, pending)
    end
  end
  return result ~= nil and linked
end

-- Menu actions refresh only after their queued write has finished. A status
-- chosen there replaces a queued "finished", even if it can't be set now.
function Cache:queueBookStatus(filename, status, callback)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  self:serializeUpdate(function(wifi_error)
    local saved = false
    if tostring(self.settings:readBookSetting(filename, "book_id")) == tostring(book_id) then
      local pending = status ~= STATUS.FINISHED
        and self.settings.pending_updates:get(filename, self.settings:readBookSettings(filename))
      if pending then
        self.settings.pending_updates:clearFinished(filename, pending)
      end
      if status ~= STATUS.FINISHED then
        self.settings.pending_updates:clearFinishedElsewhere(filename, book_id)
      end
      saved = not wifi_error and self:updateBookStatus(filename, status)
    end
    if callback then callback(saved) end
  end)
end

-- Like a status chosen in the menus, this replaces what's queued for the
-- book, even if it can't be removed now.
function Cache:queueBookRemoval(filename, callback)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  local function linked()
    return tostring(self.settings:readBookSetting(filename, "book_id")) == tostring(book_id)
  end
  self:serializeUpdate(function(wifi_error)
    local removed = false
    local pending = book_id and linked()
      and self.settings.pending_updates:get(filename, self.settings:readBookSettings(filename))
    if pending then
      self.settings.pending_updates:clearProgress(filename, pending)
      self.settings.pending_updates:clearFinished(filename, pending)
    end
    if book_id and linked() then
      self.settings.pending_updates:clearFinishedElsewhere(filename, book_id)
    end
    if not wifi_error and book_id and self.settings:providerEnabled() and linked() then
      local status, err = self.provider:findUserBookFor(self.settings:readBookSettings(filename))
      if not err and status and status.id and self.settings:providerEnabled() and linked() then
        if self.api:removeRead(status.id) and linked() then
          self.state.book_status = {}
          self.state.locally_finished_book_id = nil
          -- Known to have no status there until another is read or set, so
          -- closing the book doesn't queue its position.
          self.state.removed_status = self.state.book_status
          removed = true
        end
      end
    end
    if callback then callback(removed) end
  end)
end

-- Refreshes the open book's remote status. Once it's closed, which clears
-- that, `filename`'s is looked up by its own link instead, e.g. for a review
-- that waited for its turn.
function Cache:cacheUserBook(filename)
  local document = self.ui and self.ui.document
  if not document then
    local book = filename and self.settings:readBookSettings(filename)
    if not (book and book.book_id) then
      return nil
    end
    local status, errors = self.provider:findUserBookFor(book)
    self.state.book_status = status or {}
    self.state.locally_finished_book_id = nil
    return errors
  end

  filename = document.file
  local status, errors = self.api:findUserBook(self.settings:getLinkedBookId(), self.user:getId())
  self.state.book_status = status or {}
  self.state.locally_finished_book_id = nil
  if status and status.page_count and status.page_count > 0 then
    local current_pages = self.settings:readBookSetting(filename, "pages")
    if not current_pages or current_pages == 0 then
      self.settings:updateBookSetting(filename, { pages = status.page_count })
    end
  end
  return errors
end

return Cache
