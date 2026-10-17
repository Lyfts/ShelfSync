-- LibraryThing keeps no reading progress, so the sync engine only sends the
-- end of a book there: other progress mustn't turn Wi-Fi on (as "Enable wifi
-- on demand" would, e.g. on a Kindle), make requests, or be queued.

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr = mocks.UIManager, mocks.NetworkMgr

local LuaSettings = require("luasettings")
local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local LibraryThing = require("shelfsync/lib/librarything/provider")
local LibraryThingSettings = require("shelfsync/lib/librarything/settings")
local LibraryThingApi = require("shelfsync/lib/librarything/api")
local LIBRARYTHING = require("shelfsync/lib/librarything/constants")

local STATUS = LIBRARYTHING.STATUS
local FILE = "/books/test.epub"

describe("SyncEngine with LibraryThing", function()
  local engine, settings, calls, wifi_uses, current_page, confirms

  before_each(function()
    mocks.reset()
    NetworkMgr._wifi_on, NetworkMgr._connected = true, true
    current_page = 1
    confirms = {}

    local document = {
      file = FILE,
      getProps = function() return { title = "Oathbringer", authors = "Brandon Sanderson" } end,
      getPageCount = function() return 300 end,
    }
    local ui = {
      document = document,
      highlight = { addToHighlightDialog = function() end, removeFromHighlightDialog = function() end },
      getCurrentPage = function() return current_page end,
    }
    settings = LibraryThingSettings:new("/settings/librarything.lua", ui, nil)
    settings:updateSetting(SETTING.LIBRARYTHING.SESSION_COOKIE, "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc")
    settings:updateBookSetting(FILE, { book_id = "16471009", title = "Oathbringer" })

    calls = { findUserBook = 0, updateUserBook = {} }
    local api = setmetatable({
      settings = settings,
      findUserBook = function(_, work_id)
        calls.findUserBook = calls.findUserBook + 1
        return { id = "9", book_id = work_id, status_id = STATUS.READING }
      end,
      updateUserBook = function(_, work_id, status_id)
        table.insert(calls.updateUserBook, status_id)
        return { id = "9", book_id = work_id, status_id = status_id }
      end,
    }, { __index = LibraryThingApi })

    local state = { book_status = { id = "9", book_id = "16471009", status_id = STATUS.READING } }
    local wifi = AutoWifi:new { settings = settings, label = "LibraryThing" }
    wifi_uses = 0
    local withWifi = wifi.withWifi
    wifi.withWifi = function(...)
      wifi_uses = wifi_uses + 1
      return withWifi(...)
    end
    local user = { getId = function() return 1 end }
    local cache = Cache:new { settings = settings, api = api, user = user, state = state, ui = ui, wifi = wifi }
    local page_mapper = {
      cachePageMap = function() end,
      getRemotePagePercent = function(_, page, document_pages) return page / document_pages, nil end,
    }
    engine = SyncEngine:new {
      label = "LibraryThing", constants = LIBRARYTHING, highlight_menu_name = "hl_lt",
      api = api, user = user, cache = cache, page_mapper = page_mapper, wifi = wifi,
      dialog_manager = { confirm = function(_, options) table.insert(confirms, options.text) end },
      provider = LibraryThing:new {
        label = "LibraryThing", api = api, user = user, cache = cache, dialog_manager = {},
        page_mapper = page_mapper, settings = settings, state = state, ui = ui, wifi = wifi,
      },
      settings = settings, plugin_settings = settings, ui = ui, view = {}, state = state,
    }
    cache.provider = engine.provider
    engine:initializePageUpdate()
  end)

  local function queued()
    local updates = LuaSettings:open(settings.pending_updates.path):readSetting("updates")
    return updates and updates[FILE]
  end

  it("sends nothing, and doesn't use Wi-Fi, for progress short of the end", function()
    local result, reason
    engine:_handlePageUpdate(FILE, 40, true, function(r, why) result, reason = r, why end, "percentage")
    UIManager:_runUntilIdle()

    assert.is_nil(result)
    assert.matches("doesn't keep reading progress", reason, 1, true)
    assert.equals(0, wifi_uses)
    assert.equals(0, calls.findUserBook)
    assert.same({}, calls.updateUserBook)
  end)

  it("marks the book as Read once it reaches the end", function()
    local result
    engine:_handlePageUpdate(FILE, 100, true, function(r) result = r end, "percentage")
    UIManager:_runUntilIdle()

    assert.same({ STATUS.FINISHED }, calls.updateUserBook)
    assert.equals(STATUS.FINISHED, result.status_id)
    assert.equals(STATUS.FINISHED, engine.state.book_status.status_id)
  end)

  it("doesn't ask to mark a book that's already Read as reading when it's opened at its end", function()
    engine.state.book_status.status_id = STATUS.FINISHED
    local result, reason
    engine:_handlePageUpdate(FILE, 100, true, function(r, why) result, reason = r, why end, "percentage")
    UIManager:_runUntilIdle()

    assert.is_nil(result)
    assert.matches("not currently marked as reading", reason, 1, true)
    assert.same({}, confirms)
    assert.same({}, calls.updateUserBook)
  end)

  it("doesn't queue the position a book is closed at short of the end", function()
    current_page = 120
    engine:_queueClosingProgress()
    assert.is_nil(queued())

    current_page = 300
    engine:_queueClosingProgress()
    assert.equals(100, queued().progress.value)
  end)
end)
