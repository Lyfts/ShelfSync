-- wrapper around goodreads_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local math = require("math")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Book = require("shelfsync/lib/common/book")

local SETTING = require("shelfsync/lib/common/constants/settings")
local GOODREADS = require("shelfsync/lib/goodreads/constants")

-- Goodreads' legacy write endpoints don't require an existing reading
-- session to already exist (unlike StoryGraph), so SyncEngine shouldn't bail
-- out of a page update just because findUserBook couldn't read one back --
-- see the note on getRemoteProgress below for why there's nothing to read.
local Goodreads = {
  allows_new_read = true,
}
Goodreads.__index = Goodreads

function Goodreads:new(o)
  return setmetatable(o, self)
end

function Goodreads:showLinkBookDialog(force_search, link_callback)
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

function Goodreads:linkBook(book)
  local filename = self.ui.document.file

  local status = self.api:findUserBook(book.book_id) or {}

  local delete = {}
  local clear_keys = { "book_id", "edition_id", "pages", "title" }
  for _, key in ipairs(clear_keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end

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

function Goodreads:findBookOptions(force_search)
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

function Goodreads:autolinkBook(book)
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

function Goodreads:linkBookByIsbn(identifiers)
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

function Goodreads:linkBookByTitle()
  local props = self.ui.document:getProps()

  local results = self.api:findBooks(props.title, props.authors, self.user:getId())
  if results and #results > 0 then
    self:autolinkBook(results[1])
    return true
  end
end

-- `done` (optional) is called once the attempt is fully resolved, whether or
-- not it found a match -- including when `withWifi` has to wait on a wifi
-- restore before it can run. Callers that need to know the outcome MUST use
-- `done` rather than checking bookLinked() immediately after calling this.
function Goodreads:tryAutolink(done)
  if self.settings:bookLinked() then
    if done then done() end
    return
  end

  local props = self.ui.document:getProps()

  local identifiers = Book:parseIdentifiers(props.identifiers)
  local should_attempt = ((identifiers.isbn_10 or identifiers.isbn_13) and self.settings:readSetting(SETTING.LINK_BY_ISBN))
    or (props.title and self.settings:readSetting(SETTING.LINK_BY_TITLE))
  self.settings:debugLog("Goodreads: tryAutolink - should_attempt=" .. tostring(should_attempt))
  if should_attempt then
    self.wifi:withWifi(function()
      self:_runAutolink(identifiers)
      if done then done() end
    end)
  elseif done then
    done()
  end
end

local function percentToPage(percent, total_pages)
  if not percent or not total_pages or total_pages <= 0 then
    return nil
  end
  return math.floor((percent / 100) * total_pages + 0.5)
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

-- Writes a page-progress update to Goodreads and returns the refreshed
-- status, or nil plus an error reason on failure. `value` may be a page
-- number or a percentage depending on `update_type`; it's always converted
-- to a page number before writing, since that's all /user_status.json
-- accepts. Automatically moves the book to "Read" once the pushed page
-- reaches the known total (Goodreads has no percent_finished field to key
-- this off of like StoryGraph does).
function Goodreads:pushProgress(_current_read, value, update_type, filename)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return nil, "No linked book found on Goodreads"
  end

  local page = value
  if update_type ~= "pages" then
    page = percentToPage(value, tonumber(self.settings:pages()))
    if not page then
      return nil, "Goodreads: linked book has no known page count"
    end
  else
    page = math.floor(page + 0.5)
  end

  local result = self.api:updatePage(book_id, page)
  if not result then
    return nil
  end

  if result.status_id == GOODREADS.STATUS.READING
      and tonumber(result.book_num_of_pages) and result.book_num_of_pages > 0
      and page >= result.book_num_of_pages then
    local finished = self.api:updateUserBook(book_id, GOODREADS.STATUS.FINISHED)
    if finished then
      result = finished
    end
  end

  return result
end

function Goodreads:_runAutolink(identifiers)
  local linked = false
  if self.settings:readSetting(SETTING.LINK_BY_ISBN) then
    linked = self:linkBookByIsbn(identifiers)
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_TITLE) then
    linked = self:linkBookByTitle()
  end

  if not linked then
    self.settings:debugLog("Goodreads: _runAutolink - no method found a match, book stays unlinked")
  end
end

return Goodreads
