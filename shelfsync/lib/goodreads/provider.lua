-- wrapper around goodreads_api to add higher level methods
local _ = require("gettext")
local logger = require("shelfsync/lib/common/safe_logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local GOODREADS = require("shelfsync/lib/goodreads/constants")

-- Goodreads' legacy write endpoints don't require an existing reading
-- session to already exist (unlike StoryGraph), so SyncEngine shouldn't bail
-- out of a page update just because findUserBook couldn't read one back --
-- see the note on getRemoteProgress below for why there's nothing to read.
local Goodreads = setmetatable({
  allows_new_read = true,
  -- See getRemoteProgress.
  has_remote_progress = false,
}, { __index = BaseProvider })
Goodreads.__index = Goodreads

function Goodreads:linkBook(book, link_method)
  local filename = self.ui.document.file

  local status, lookup_error = self.api:findUserBook(book.book_id)
  status = status or {}

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "pages", "title" })

  local new_settings = {
    book_id = book.book_id,
    pages = book.pages or status.book_num_of_pages,
    title = book.title,
    link_method = link_method,
    _delete = delete
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  -- Only a lookup confirming the book isn't on any shelf can safely add it:
  -- after a failed lookup, or with a shelf we don't map to a status, adding
  -- it could replace a status the book already has (e.g. Read).
  if lookup_error then
    logger.warn("Goodreads: Couldn't check the book's status, not adding it to Currently Reading: " .. tostring(lookup_error))
    UIManager:show(InfoMessage:new {
      text = _("Linked, but couldn't check the book's status on Goodreads, so it wasn't marked as Currently Reading automatically. Use \"Update status\" to set it manually."),
      icon = "notice-warning",
    })
  elseif not self.state.book_status.status_id and not self.state.book_status.shelved then
    logger.info("Goodreads: Book has no status, adding to Currently Reading automatically")
    local added = self.api:updateUserBook(book.book_id, GOODREADS.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      logger.warn("Goodreads: Failed to automatically mark book as Currently Reading on Goodreads")
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't automatically mark the book as Currently Reading on Goodreads. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

-- Goodreads' book page doesn't expose the viewer's current reading position
-- anywhere (confirmed absent from the SSR payload -- only shelf status is
-- available, see api.lua's findUserBook), so there's no remote progress
-- signal to compare against. Always returning 0 means the background
-- "local is behind remote, skip this push" check in SyncEngine never
-- triggers -- an accepted tradeoff given the API has nothing better to offer.
function Goodreads:getRemoteProgress(_status, _update_type)
  return 0
end

function Goodreads:getRemotePercent(_status)
  return nil
end

-- Writes a progress update to Goodreads and returns the refreshed status, or
-- nil plus an error reason on failure. `value` is sent as-is, in
-- `update_type`'s unit -- /user_status.json takes a percent field directly,
-- so there's no local percent<->page conversion needed, and no dependence
-- on knowing the edition's page count (which findUserBook's numPages scrape
-- often fails to find). Automatically moves the book to "Read" once the
-- pushed progress reaches its known total (Goodreads has no percent_finished
-- field to key this off of like StoryGraph does).
function Goodreads:pushProgress(_current_read, value, update_type, filename)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return nil, "No linked book found on Goodreads"
  end

  local result = self.api:updateProgress(book_id, value, update_type)
  if not result then
    return nil
  end
  -- The write went through even if reading the book page back failed, so
  -- keep the status already known rather than replacing it with nothing.
  if not result.id then
    result = self.state.book_status
  end

  local finished
  if update_type == "pages" then
    finished = tonumber(result.book_num_of_pages) and result.book_num_of_pages > 0
      and value >= result.book_num_of_pages
  else
    finished = value >= 100
  end

  if result.status_id == GOODREADS.STATUS.READING and finished then
    local finished_result = self.api:updateUserBook(book_id, GOODREADS.STATUS.FINISHED)
    if finished_result and finished_result.id then
      result = finished_result
      self:onMarkedFinished(book_id, filename)
    end
  end

  return result
end

-- Stamps today as the Goodreads "date read" -- called by Cache:updateBookStatus
-- for Finished transitions that go through the shared status menu/SyncEngine,
-- and directly above for the auto-track-to-100% finished path (which
-- bypasses Cache since it needs updateUserBook's return value inline).
-- A queued "finished" is dated `finished_at`, when the book was finished.
function Goodreads:onMarkedFinished(book_id, filename, finished_at)
  self:notifyBookFinished(filename)
  finished_at = tonumber(finished_at) or os.time()
  local dated = self:setDateFinished(book_id, finished_at)
  if not dated then
    -- The shelf write may have succeeded even when Goodreads' separate
    -- finished-date editor request was interrupted or failed. Keep the
    -- original finish time so the pending-update flow can retry just the date.
    local book = self.settings and self.settings:readBookSettings(filename)
    if book and tostring(book.book_id) == tostring(book_id) and self.settings.pending_updates then
      self.settings.pending_updates:addFinished(filename, book, finished_at)
    end
  end
  return dated
end

function Goodreads:setDateFinished(book_id, finished_at)
  return self.api:setDateFinished(book_id, finished_at)
end

-- ReviewMenu entry point: submits a star rating and/or free-text review from
-- the unified Review menu. Goodreads only accepts whole-star ratings, so a
-- quarter/half-star value is rounded down to a whole number here.
function Goodreads:submitReview(filename, rating, text)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return false, "No linked book found on Goodreads"
  end

  -- Save text first so a text failure does not create a rating-only review.
  if text and text ~= "" then
    local ok, err = self.api:setReviewText(book_id, text)
    if not ok then return false, err or "Goodreads could not save the review text" end
  end
  if rating and rating > 0 then
    if not self.api:setRating(book_id, math.floor(rating)) then
      return false, "Goodreads could not save the rating"
    end
  end
  return true
end

return Goodreads
