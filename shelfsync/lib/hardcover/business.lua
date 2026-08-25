-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Book = require("shelfsync/lib/common/book")

local SETTING = require("shelfsync/lib/common/constants/settings")

-- Unlike StoryGraph, Hardcover can start a brand new read session on demand
-- (see pushProgress below), so SyncEngine shouldn't bail out of a page update
-- just because there's no existing user_book_reads entry yet.
local Hardcover = {
  allows_new_read = true,
}
Hardcover.__index = Hardcover

function Hardcover:new(o)
  return setmetatable(o, self)
end

function Hardcover:showLinkBookDialog(force_search, link_callback)
  local search_value, books, err = self:findBookOptions(force_search)

  if err then
    logger.err(err)
    return
  end

  self.dialog_manager:buildSearchDialog(
    "Select book",
    books,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      self:linkBook(book)
      if link_callback then
        link_callback()
      end
    end,
    function(search)
      self.dialog_manager:updateSearchResults(search)
      return true
    end,
    search_value
  )
end

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

  local delete = {}
  local clear_keys = { "book_id", "edition_id", "edition_format", "pages", "title" }
  for _, key in ipairs(clear_keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end

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
  end

  return true
end

-- could be moved to book search model
function Hardcover:findBookOptions(force_search)
  local props = self.ui.document:getProps()
  local identifiers = Book:parseIdentifiers(props.identifiers)
  local user_id = self.user:getId()

  if not force_search then
    local book_lookup = self.api:findBookByIdentifiers(identifiers, user_id)
    if book_lookup then
      return nil, { book_lookup }
    end
  end

  local title = props.title
  if not title or title == "" then
    local _dir, path = util.splitFilePathName(self.ui.document.file)
    local filename, _suffix = util.splitFileNameSuffix(path)

    title = filename:gsub("_", " ")
  end
  local result, err = self.api:findBooks(title, props.authors, user_id)
  return title, result, err
end

function Hardcover:autolinkBook(book)
  if not book then
    return
  end

  local linked = self:linkBook(book)
  if linked then
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end
end

function Hardcover:linkBookByIsbn(identifiers)
  if identifiers.isbn_10 or identifiers.isbn_13 then
    local user_id = self.user:getId()
    local book_lookup = self.api:findBookByIdentifiers({
      isbn_10 = identifiers.isbn_10,
      isbn_13 = identifiers.isbn_13
    },
      user_id
    )
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function Hardcover:linkBookByHardcover(identifiers)
  if identifiers.book_slug or identifiers.edition_id then
    local user_id = self.user:getId()
    local book_lookup = self.api:findBookByIdentifiers(
      { book_slug = identifiers.book_slug, edition_id = identifiers.edition_id }, user_id)
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function Hardcover:linkBookByTitle()
  local props = self.ui.document:getProps()

  local results = self.api:findBooks(props.title, props.authors, self.user:getId())
  if results and #results > 0 then
    self:autolinkBook(results[1])
    return true
  end
end

function Hardcover:tryAutolink()
  if self.settings:bookLinked() then
    return
  end

  local props = self.ui.document:getProps()

  local identifiers = Book:parseIdentifiers(props.identifiers)
  local should_attempt = ((identifiers.isbn_10 or identifiers.isbn_13) and self.settings:readSetting(SETTING.LINK_BY_ISBN))
    or ((identifiers.book_slug or identifiers.edition_id) and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER))
    or (props.title and self.settings:readSetting(SETTING.LINK_BY_TITLE))
  self.settings:debugLog("Hardcover: tryAutolink - should_attempt=" .. tostring(should_attempt)
    .. " isbn_10=" .. tostring(identifiers.isbn_10) .. " isbn_13=" .. tostring(identifiers.isbn_13)
    .. " book_slug=" .. tostring(identifiers.book_slug) .. " title=" .. tostring(props.title))
  if should_attempt then
    self.wifi:withWifi(function()
      self:_runAutolink(identifiers)
    end)
  end
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

function Hardcover:_runAutolink(identifiers)
  local linked = false
  if self.settings:readSetting(SETTING.LINK_BY_ISBN) then
    linked = self:linkBookByIsbn(identifiers)
    self.settings:debugLog("Hardcover: _runAutolink - linkBookByIsbn linked=" .. tostring(linked))
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) then
    linked = self:linkBookByHardcover(identifiers)
    self.settings:debugLog("Hardcover: _runAutolink - linkBookByHardcover linked=" .. tostring(linked))
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_TITLE) then
    linked = self:linkBookByTitle()
    self.settings:debugLog("Hardcover: _runAutolink - linkBookByTitle linked=" .. tostring(linked))
  end

  if not linked then
    self.settings:debugLog("Hardcover: _runAutolink - no method found a match, book stays unlinked")
  end
end

return Hardcover
