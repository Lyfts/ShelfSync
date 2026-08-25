-- wrapper around storygraph_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Book = require("shelfsync/lib/common/book")

local SETTING = require("shelfsync/lib/common/constants/settings")
local STORYGRAPH = require("shelfsync/lib/storygraph/constants")

local StoryGraph = {}
StoryGraph.__index = StoryGraph

function StoryGraph:new(o)
  return setmetatable(o, self)
end

function StoryGraph:showLinkBookDialog(force_search, link_callback)
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

function StoryGraph:showChangeEditionDialog(callback)
  local editions = self.api:findEditions(self.settings:getLinkedBookId(), self.user:getId())
  self.dialog_manager:buildSearchDialog(
    "Select edition",
    editions,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      if book.book_id ~= self.settings:getLinkedBookId() then
        local success = self.api:switchEdition(self.settings:getLinkedBookId(), book.book_id)
        if not success then
          self.dialog_manager:showError("Failed to switch edition on StoryGraph. Please try again.")
          return
        end
      end
      self:linkBook(book)
      if callback then
        callback(book)
      end
    end
  )
end

function StoryGraph:linkBook(book)
  local filename = self.ui.document.file

  -- 1. Fetch remote status (API handles redirection and audio filtering internally)
  local status = self.api:findUserBook(book.book_id) or {}

  -- 2. If the final resolved edition is Audio, fail the linking process
  if status.is_audio then
    logger.warn("StoryGraph: Cannot link to an Audio edition.")
    UIManager:show(InfoMessage:new{
      text = _("StoryGraph: Cannot link to an Audio edition. Please select a text-based edition.")
    })
    return false
  end

  -- 3. If findUserBook resolved to a different (non-audio) edition, use that ID instead
  if status.id and status.id ~= book.book_id then
    logger.info("StoryGraph: Redirecting link to your active edition: " .. status.id)
    book.book_id = status.id
    book.pages = status.book_num_of_pages or book.pages
  end

  local delete = {}
  local clear_keys = { "book_id", "edition_id", "edition_format", "pages", "title" }
  for _, key in ipairs(clear_keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end

  local new_settings = {
    book_id = book.book_id,
    edition_format = status.edition_format or Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  -- 3. Save link information
  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  -- 4. Auto-Add to Library if no status was found on ANY edition
  if not self.state.book_status.status_id then
    logger.info("StoryGraph: Book has no status on any edition, adding to Currently Reading automatically")
    local added = self.api:updateUserBook(book.book_id, STORYGRAPH.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      -- The book stays linked locally either way (settings already saved
      -- above), but without this the failure was completely silent -- the
      -- book would just sit unsynced until the status-mismatch warning
      -- eventually caught it much later, with no link back to the cause.
      logger.warn("StoryGraph: Failed to automatically mark book as Currently Reading on StoryGraph")
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't automatically mark the book as Currently Reading on StoryGraph. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

-- could be moved to book search model
function StoryGraph:findBookOptions(force_search)
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

function StoryGraph:autolinkBook(book)
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

function StoryGraph:linkBookByIsbn(identifiers)
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

function StoryGraph:linkBookByHardcover(identifiers)
  if identifiers.book_slug then
    local user_id = self.user:getId()
    local book_lookup = self.api:findBookByIdentifiers(
      { book_slug = identifiers.book_slug }, user_id)
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function StoryGraph:linkBookByTitle()
  local props = self.ui.document:getProps()

  local results = self.api:findBooks(props.title, props.authors, self.user:getId())
  if results and #results > 0 then
    self:autolinkBook(results[1])
    return true
  end
end

-- `done` (optional) is called once the attempt is fully resolved, whether or
-- not it found a match -- including when `withWifi` has to wait on a wifi
-- restore before it can run. Callers that need to know the outcome (e.g.
-- SyncEngine's startReadCache retry chain) MUST use `done` rather than
-- checking bookLinked() immediately after calling this, since a wifi wait
-- means linking can finish well after this function itself returns.
function StoryGraph:tryAutolink(done)
  if self.settings:bookLinked() then
    if done then done() end
    return
  end

  local props = self.ui.document:getProps()

  local identifiers = Book:parseIdentifiers(props.identifiers)
  local should_attempt = ((identifiers.isbn_10 or identifiers.isbn_13) and self.settings:readSetting(SETTING.LINK_BY_ISBN))
    or ((identifiers.book_slug or identifiers.edition_id) and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER))
    or (props.title and self.settings:readSetting(SETTING.LINK_BY_TITLE))
  self.settings:debugLog("StoryGraph: tryAutolink - should_attempt=" .. tostring(should_attempt)
    .. " isbn_10=" .. tostring(identifiers.isbn_10) .. " isbn_13=" .. tostring(identifiers.isbn_13)
    .. " book_slug=" .. tostring(identifiers.book_slug) .. " title=" .. tostring(props.title))
  if should_attempt then
    self.wifi:withWifi(function()
      self:_runAutolink(identifiers)
      if done then done() end
    end)
  elseif done then
    done()
  end
end

-- Remote progress in `update_type`'s unit, read from a cached book_status
-- table (e.g. self.state.book_status), used by SyncEngine to skip a
-- background write that would move progress backward.
function StoryGraph:getRemoteProgress(status, update_type)
  if update_type == "pages" then
    return tonumber(status and status.last_reached_pages) or 0
  end
  return tonumber(status and status.percent_finished) or 0
end

-- Overall remote completion percent (0-100), or nil if unknown. Used by
-- "Jump to position" and to seed the note dialog's remote-percent hint.
function StoryGraph:getRemotePercent(status)
  return tonumber(status and status.last_reached_percent) or 0
end

-- Writes a progress update to StoryGraph and returns the refreshed status, or
-- nil plus an error reason on failure. Also auto-marks the book Finished when
-- the write pushes it to 100% while still Currently Reading.
function StoryGraph:pushProgress(current_read, value, update_type, filename)
  if not current_read then
    return nil, "No active reading session found on StoryGraph"
  end

  local result = self.api:updatePage(current_read.id, value, current_read.started_at, update_type)
  if not result then
    return nil
  end

  if (tonumber(result.percent_finished) or 0) >= 100 and result.status_id == STORYGRAPH.STATUS.READING then
    local book_id = self.settings:readBookSetting(filename, "book_id")
    if book_id then
      local finished = self.api:updateUserBook(book_id, STORYGRAPH.STATUS.FINISHED)
      if finished then
        result = finished
      end
    end
  end

  return result
end

function StoryGraph:_runAutolink(identifiers)
  local linked = false
  if self.settings:readSetting(SETTING.LINK_BY_ISBN) then
    linked = self:linkBookByIsbn(identifiers)
    self.settings:debugLog("StoryGraph: _runAutolink - linkBookByIsbn linked=" .. tostring(linked))
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) then
    linked = self:linkBookByHardcover(identifiers)
    self.settings:debugLog("StoryGraph: _runAutolink - linkBookByHardcover linked=" .. tostring(linked))
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_TITLE) then
    linked = self:linkBookByTitle()
    self.settings:debugLog("StoryGraph: _runAutolink - linkBookByTitle linked=" .. tostring(linked))
  end

  if not linked then
    self.settings:debugLog("StoryGraph: _runAutolink - no method found a match, book stays unlinked")
  end
end

return StoryGraph
