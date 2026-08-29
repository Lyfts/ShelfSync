-- wrapper around fable_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local Book = require("shelfsync/lib/common/book")
local FABLE = require("shelfsync/lib/fable/constants")

-- Fable's shelving endpoint doesn't require an existing reading_progress
-- entry to exist first (confirmed via HAR: book_lists/book succeeds
-- independent of reading_progress state), so -- same reasoning as
-- Goodreads -- SyncEngine shouldn't bail out of a page update just because
-- findUserBook came back with no user_book_reads to key off of.
local Fable = setmetatable({
  allows_new_read = true,
}, { __index = BaseProvider })
Fable.__index = Fable

function Fable:linkBook(book)
  local filename = self.ui.document.file

  local status = self.api:findUserBook(book.book_id) or {}

  -- Only worth an extra editions/ fetch here at link time -- see
  -- api.lua's findEditionPageCount for why findUserBook itself doesn't
  -- resolve a page count on every call.
  local pages = book.page_count
  if not pages or pages == 0 then
    local props = self.ui.document:getProps()
    local identifiers = Book:parseIdentifiers(props.identifiers)
    local isbn = identifiers.isbn_13 or identifiers.isbn_10 or book.isbn
    pages = self.api:findEditionPageCount(book.book_id, isbn)
  end

  local new_settings = { book_id = book.book_id, title = book.title }
  local delete = {}
  if pages and pages > 0 then
    new_settings.pages = pages
  else
    table.insert(delete, "pages")
  end
  new_settings._delete = delete

  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  if not self.state.book_status.status_id then
    logger.info("Fable: Book has no status, adding to Currently Reading automatically")
    local added = self.api:updateUserBook(book.book_id, FABLE.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      logger.warn("Fable: Failed to automatically mark book as Currently Reading on Fable")
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't automatically mark the book as Currently Reading on Fable. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

-- Fable's book-detail endpoint has no reading-position field either (only
-- shelf status, see api.lua's findUserBook), same situation as Goodreads --
-- there's no remote progress signal to compare a local push against.
function Fable:getRemoteProgress(_status, _update_type)
  return 0
end

function Fable:getRemotePercent(_status)
  return nil
end

-- Writes a progress update to Fable and returns the refreshed status, or nil
-- on failure. Moves the book to Fable's "Finished" list once the pushed
-- value reaches its known total, same as Goodreads (Fable's
-- reading_progress response has no percent_finished-style field to key this
-- off of instead).
function Fable:pushProgress(_current_read, value, update_type, filename)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return nil, "No linked book found on Fable"
  end

  local result = self.api:updateProgress(book_id, value, update_type)
  if not result then
    return nil
  end

  local finished
  if update_type == "pages" then
    local pages = self.settings:readBookSetting(filename, "pages")
    finished = pages and pages > 0 and value >= pages
  else
    finished = value >= 100
  end

  if result.status_id == FABLE.STATUS.READING and finished then
    local finished_result = self.api:updateUserBook(book_id, FABLE.STATUS.FINISHED)
    if finished_result then
      result = finished_result
      self:onMarkedFinished(book_id, filename)
    end
  end

  return result
end

-- ReviewMenu entry point. Fable accepts fractional ratings, so the
-- quarter-star value is passed through unrounded.
function Fable:submitReview(filename, rating, text)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return false, "No linked book found on Fable"
  end

  local review_rating = rating and rating > 0 and rating or nil
  return self.api:setReview(book_id, review_rating, text) == true
end

return Fable
