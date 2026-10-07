-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("shelfsync/lib/common/safe_logger")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Book = require("shelfsync/lib/common/book")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")

local function formatApiError(err)
  if type(err) == "string" then
    return err
  end
  if type(err) ~= "table" then
    return "no status returned"
  end

  local errors = err.errors
  if type(errors) == "table" then
    local messages = {}
    for _, item in ipairs(errors) do
      if type(item) == "table" then
        table.insert(messages, tostring(item.message or item.error or "GraphQL error"))
      else
        table.insert(messages, tostring(item))
      end
    end
    if #messages > 0 then
      return table.concat(messages, "; ")
    end
  end

  if err.message or err.error then
    return tostring(err.message or err.error)
  end
  if err.completed == false then
    return "request did not complete"
  end
  return "no status returned"
end

-- Unlike StoryGraph, Hardcover can start a brand new read session on demand
-- (see pushProgress below), so SyncEngine shouldn't bail out of a page update
-- just because there's no existing user_book_reads entry yet.
local Hardcover = setmetatable({
  allows_new_read = true,
  requires_remote_page_count = true,
  -- A book findUserBook finds no status for isn't on the user's shelves,
  -- rather than possibly on a page that loaded without them (Goodreads).
  has_reliable_status = true,
}, { __index = BaseProvider })
Hardcover.__index = Hardcover

function Hardcover:cacheRandomBooks()
  local user_id = self.user:getId()

  local books, error = self.api:getRandomToRead(user_id, 10)
  if error then
    UIManager:show(InfoMessage:new {
      text = _("Error fetching to-read list"),
      icon = "notice-warning",
      timeout = 2
    })
    return
  end

  self.state.random_books = books
  return books
end

function Hardcover:showRandomBookDialog()
  self.wifi:wifiPrompt(function(wifi_enabled)
    local books = self.state.random_books
    if not books then
      books = self:cacheRandomBooks()
    end

    if not self.state.random_books or #self.state.random_books == 0 then
      UIManager:show(Notification:new {
        text = "No books found on Want to Read list",
        timeout = 4
      })

      if wifi_enabled then
        UIManager:nextTick(function()
          self.wifi:wifiDisablePrompt()
        end)
      end

      return
    end

    self.dialog_manager:buildBookListDialog("Suggest a book", self.state.random_books, function()
      books = self:cacheRandomBooks()
      if books then
        self.dialog_manager:updateRandomBooks(books)
      end
    end, wifi_enabled)
  end)
end

function Hardcover:changeBookVisibility(visibility)
  local filename = self.settings:getFilePath()
  local book_id = self.settings:readBookSetting(filename, "book_id")
  -- Still sent if the book's closed before its turn, as long as its link hasn't changed.
  local function linked()
    return book_id and tostring(self.settings:readBookSetting(filename, "book_id")) == tostring(book_id)
  end
  self.cache:serializeUpdate(function(wifi_error)
    if wifi_error or not linked() then return end
    self.cache:cacheUserBook(filename)
    if linked() and self.state.book_status.id
        and not self.cache:updateBookStatus(filename, self.state.book_status.status_id, visibility) then
      self.dialog_manager:showError("Book status could not be updated")
    end
  end)
end

function Hardcover:linkBook(book, link_method)
  local filename = self.ui.document.file

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "edition_format", "pages", "title" })

  local new_settings = {
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    link_method = link_method,
    _delete = delete
  }

  self.settings:updateBookSetting(filename, new_settings)
  local lookup_error = self.cache:cacheUserBook()

  if book.book_id and self.state.book_status.id then
    if new_settings.edition_id and new_settings.edition_id ~= self.state.book_status.edition_id then
      -- update edition
      self.state.book_status = self.api:updateUserBook(
        new_settings.book_id,
        self.state.book_status.status_id,
        self.state.book_status.privacy_setting_id,
        new_settings.edition_id
      ) or {}
    end
  elseif book.book_id and lookup_error then
    -- A failed lookup isn't proof the book has no status, and adding it
    -- could replace one it already has (e.g. Read).
    logger.warn("Hardcover: Couldn't check the book's status, not adding it to Currently Reading: " .. formatApiError(lookup_error))
    UIManager:show(InfoMessage:new {
      text = _("Linked, but couldn't check the book's status on Hardcover, so it wasn't marked as Currently Reading automatically. Use \"Update status\" to set it manually."),
      icon = "notice-warning",
    })
  elseif book.book_id and not self.state.book_status.status_id then
    -- Auto-Add to Library if no status was found (mirrors StoryGraph:linkBook)
    logger.info("Hardcover: Book has no status, adding to Currently Reading automatically")
    -- Match the known-good manual status action's insert payload. The
    -- selected edition remains in local settings and is sent with progress
    -- updates.
    local added, status_error = self.api:updateUserBook(new_settings.book_id, HARDCOVER.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      -- The book stays linked locally either way (settings already saved
      -- above), but without this the failure was completely silent -- the
      -- book would just sit unsynced until the status-mismatch warning
      -- eventually caught it much later, with no link back to the cause.
      logger.warn("Hardcover: Failed to automatically mark book as Currently Reading on Hardcover: " .. formatApiError(status_error))
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't automatically mark the book as Currently Reading on Hardcover. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

-- Hardcover's API only stores progress as an absolute page number, so both
-- the local trigger value and the cached remote value must be normalized to
-- `update_type`'s unit (percentage or pages) for SyncEngine's "is local
-- behind remote" comparison to stay apples-to-apples regardless of which
-- tracking trigger is in use.
local function pageToPercent(page, total_pages)
  if not page or not total_pages or total_pages <= 0 then
    return nil
  end
  return math.floor((page / total_pages) * 100 + 0.5)
end

local function percentToPage(percent, total_pages)
  if not percent or not total_pages or total_pages <= 0 then
    return nil
  end
  return math.floor((percent / 100) * total_pages + 0.5)
end

-- Remote progress in `update_type`'s unit, read from a cached book_status
-- table (e.g. self.state.book_status), used by SyncEngine to skip a
-- background write that would move progress backward. `filename` defaults
-- to the open document.
function Hardcover:getRemoteProgress(status, update_type, filename)
  local reads = status and status.user_book_reads
  local current_read = reads and reads[#reads]
  local remote_page = (current_read and tonumber(current_read.progress_pages)) or 0

  if update_type == "pages" then
    return remote_page
  end

  return pageToPercent(remote_page, tonumber(self.settings:pages(filename))) or 0
end

-- Overall remote completion percent (0-100), or nil if unknown (no active
-- read, or the linked edition has no known page count). Used by
-- "Jump to position" and to seed the note dialog's remote-percent hint.
function Hardcover:getRemotePercent(status)
  local reads = status and status.user_book_reads
  local current_read = reads and reads[#reads]
  local page = current_read and tonumber(current_read.progress_pages)
  return pageToPercent(page, tonumber(self.settings:pages()))
end

-- A percentage needs a page count to be converted to a page number.
function Hardcover:canPushProgress(update_type, filename)
  return update_type == "pages" or tonumber(self.settings:pages(filename)) ~= nil
end

-- Writes a page-progress update to Hardcover and returns the refreshed
-- status, or nil plus an error reason on failure. `value` may be a page
-- number or a percentage depending on `update_type`; it's always converted
-- to a page number before writing, since that's all Hardcover accepts.
-- Creates a new read session if the book doesn't have one yet, rather than
-- requiring one to exist. `status` defaults to the open book's cached one;
-- queued updates for other books pass their own.
function Hardcover:pushProgress(current_read, value, update_type, filename, status)
  local edition_id = self.settings:readBookSetting(filename, "edition_id")

  local page = value
  if update_type ~= "pages" then
    page = percentToPage(value, tonumber(self.settings:pages(filename)))
    if not page then
      return nil, "Hardcover: linked edition has no known page count"
    end
  else
    page = math.floor(page + 0.5)
  end

  if current_read and current_read.id then
    return self.api:updatePage(current_read.id, edition_id, page, current_read.started_at)
  end

  status = status or self.state.book_status
  if not status.id then
    return nil, "No linked book found on Hardcover"
  end

  return self.api:createRead(status.id, edition_id, page, os.date("%Y-%m-%d"))
end

-- ReviewMenu entry point. Hardcover only accepts half-star increments, so a
-- quarter-star value is rounded down to a half star here.
function Hardcover:submitReview(filename, rating, text)
  if self.cache then self.cache:cacheUserBook(filename) end
  local user_book_id = self.state.book_status and self.state.book_status.id
  if not user_book_id then
    return false, "No linked book found on Hardcover"
  end

  local rounded_rating = rating and rating > 0 and (math.floor(rating * 2) / 2) or nil
  local review_text = (text and text ~= "") and text or nil
  local result, err = self.api:updateReview(user_book_id, rounded_rating, review_text)
  return result ~= nil, err
end

return Hardcover
