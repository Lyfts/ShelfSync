-- Shared book-linking/autolink logic for all sync providers (StoryGraph,
-- Hardcover, Goodreads).
--
-- Provider-specific classes extend this via metatable inheritance, same
-- pattern as base_settings.lua:
--
--   local Hardcover = setmetatable({ allows_new_read = true }, { __index = BaseProvider })
--   Hardcover.__index = Hardcover
--
-- Providers still implement their own linkBook, getRemoteProgress,
-- getRemotePercent and pushProgress, since those differ per API. `self.label`
-- (e.g. "StoryGraph") must be set on the instance -- it's used to prefix the
-- debug log lines below, same as menu.lua/auto_wifi.lua's `label`.
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")

local Book = require("shelfsync/lib/common/book")
local SETTING = require("shelfsync/lib/common/constants/settings")

local BaseProvider = {}
BaseProvider.__index = BaseProvider

function BaseProvider:new(o)
  return setmetatable(o, self)
end

-- Keys of `book` that should be deleted (rather than written as nil) from
-- the sidecar when linking, e.g. a search result that carries no page count.
function BaseProvider:_deletedKeys(book, keys)
  local delete = {}
  for _, key in ipairs(keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end
  return delete
end

function BaseProvider:showLinkBookDialog(force_search, link_callback)
  Trapper:wrap(function()
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
  end)
end

-- could be moved to book search model
function BaseProvider:findBookOptions(force_search)
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

function BaseProvider:autolinkBook(book)
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

function BaseProvider:linkBookByIsbn(identifiers)
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

function BaseProvider:linkBookByTitle()
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
function BaseProvider:tryAutolink(done)
  if self.settings:bookLinked() then
    if done then done() end
    return
  end

  local props = self.ui.document:getProps()

  local identifiers = Book:parseIdentifiers(props.identifiers)
  local should_attempt = ((identifiers.isbn_10 or identifiers.isbn_13) and self.settings:readSetting(SETTING.LINK_BY_ISBN) ~= false)
    or (props.title and self.settings:readSetting(SETTING.LINK_BY_TITLE) ~= false)
  self.settings:debugLog(self.label .. ": tryAutolink - should_attempt=" .. tostring(should_attempt)
    .. " isbn_10=" .. tostring(identifiers.isbn_10) .. " isbn_13=" .. tostring(identifiers.isbn_13)
    .. " title=" .. tostring(props.title))
  if should_attempt then
    self.wifi:withWifi(function()
      -- _runAutolink hits the network (findBookByIdentifiers/findBooks) via
      -- api:request(), which only gets a cancellable, non-UI-blocking
      -- subprocess out of Trapper:dismissableRunInSubprocess() when called
      -- from inside a Trapper:wrap() coroutine -- otherwise it silently
      -- falls back to a fully blocking in-process call. showLinkBookDialog
      -- (the manual search-and-link flow) already wraps for this reason;
      -- this is the same requirement for the automatic path triggered on
      -- document open / LINK_BY_ISBN/LINK_BY_TITLE settings changes.
      Trapper:wrap(function()
        self:_runAutolink(identifiers)
        if done then done() end
      end)
    end)
  elseif done then
    done()
  end
end

function BaseProvider:_runAutolink(identifiers)
  local linked = false
  if self.settings:readSetting(SETTING.LINK_BY_ISBN) ~= false then
    linked = self:linkBookByIsbn(identifiers)
    self.settings:debugLog(self.label .. ": _runAutolink - linkBookByIsbn linked=" .. tostring(linked))
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_TITLE) ~= false then
    linked = self:linkBookByTitle()
    self.settings:debugLog(self.label .. ": _runAutolink - linkBookByTitle linked=" .. tostring(linked))
  end

  if not linked then
    self.settings:debugLog(self.label .. ": _runAutolink - no method found a match, book stays unlinked")
  end
end

return BaseProvider
