-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Book = require("shelfsync/lib/common/book")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")

-- Unlike StoryGraph, Hardcover can start a brand new read session on demand
-- (see pushProgress below), so SyncEngine shouldn't bail out of a page update
-- just because there's no existing user_book_reads entry yet.
local Hardcover = setmetatable({
  allows_new_read = true,
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

function Hardcover:updateCurrentBookStatus(status, privacy_setting_id)
  self.cache:updateBookStatus(self.ui.document.file, status, privacy_setting_id)
  if not self.state.book_status.id then
    self.dialog_manager:showError("Book status could not be updated")
  end
end

function Hardcover:changeBookVisibility(visibility)
  self.cache:cacheUserBook()

  if self.state.book_status.id then
    self:updateCurrentBookStatus(self.state.book_status.status_id, visibility)
  end
end

function Hardcover:linkBook(book)
  local filename = self.ui.document.file

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "edition_format", "pages", "title" })

  local new_settings = {
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.cache:cacheUserBook()

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
  elseif book.book_id and not self.state.book_status.status_id then
    -- Auto-Add to Library if no status was found (mirrors StoryGraph:linkBook)
    logger.info("Hardcover: Book has no status, adding to Currently Reading automatically")
    local added = self.api:updateUserBook(new_settings.book_id, HARDCOVER.STATUS.READING, nil, new_settings.edition_id)
    if added and added.status_id then
      self.state.book_status = added
    else
      -- The book stays linked locally either way (settings already saved
      -- above), but without this the failure was completely silent -- the
      -- book would just sit unsynced until the status-mismatch warning
      -- eventually caught it much later, with no link back to the cause.
      logger.warn("Hardcover: Failed to automatically mark book as Currently Reading on Hardcover")
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
-- background write that would move progress backward.
function Hardcover:getRemoteProgress(status, update_type)
  local reads = status and status.user_book_reads
  local current_read = reads and reads[#reads]
  local remote_page = (current_read and tonumber(current_read.progress_pages)) or 0

  if update_type == "pages" then
    return remote_page
  end

  return pageToPercent(remote_page, tonumber(self.settings:pages())) or 0
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

-- Writes a page-progress update to Hardcover and returns the refreshed
-- status, or nil plus an error reason on failure. `value` may be a page
-- number or a percentage depending on `update_type`; it's always converted
-- to a page number before writing, since that's all Hardcover accepts.
-- Creates a new read session if the book doesn't have one yet, rather than
-- requiring one to exist.
function Hardcover:pushProgress(current_read, value, update_type, _filename)
  local edition_id = self.settings:getLinkedEditionId()

  local page = value
  if update_type ~= "pages" then
    page = percentToPage(value, tonumber(self.settings:pages()))
    if not page then
      return nil, "Hardcover: linked edition has no known page count"
    end
  else
    page = math.floor(page + 0.5)
  end

  if current_read and current_read.id then
    return self.api:updatePage(current_read.id, edition_id, page, current_read.started_at)
  end

  if not self.state.book_status.id then
    return nil, "No linked book found on Hardcover"
  end

  return self.api:createRead(self.state.book_status.id, edition_id, page, os.date("%Y-%m-%d"))
end

return Hardcover
