-- wrapper around goodreads_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")

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
}, { __index = BaseProvider })
Goodreads.__index = Goodreads

function Goodreads:linkBook(book)
  local filename = self.ui.document.file

  local status = self.api:findUserBook(book.book_id) or {}

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "pages", "title" })

  local new_settings = {
    book_id = book.book_id,
    pages = book.pages or status.book_num_of_pages,
    title = book.title,
    _delete = delete
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  if not self.state.book_status.status_id then
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

  local finished
  if update_type == "pages" then
    finished = tonumber(result.book_num_of_pages) and result.book_num_of_pages > 0
      and value >= result.book_num_of_pages
  else
    finished = value >= 100
  end

  if result.status_id == GOODREADS.STATUS.READING and finished then
    local finished_result = self.api:updateUserBook(book_id, GOODREADS.STATUS.FINISHED)
    if finished_result then
      result = finished_result
    end
  end

  return result
end

return Goodreads
