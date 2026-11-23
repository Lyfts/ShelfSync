-- Session-end progress tracking (#45): instead of one entry per threshold
-- crossing, record a single update with the final position when a reading
-- session ends -- the book is closed or the device sleeps. Any forward
-- movement counts, however small, and no entry is added when nothing has
-- changed since the last sync (including zero-progress entries).

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr, ReaderUI = mocks.UIManager, mocks.NetworkMgr, mocks.ReaderUI

local LuaSettings = require("luasettings")
local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local GoodreadsProvider = require("shelfsync/lib/goodreads/provider")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local GOODREADS = require("shelfsync/lib/goodreads/constants")

local FILE = "/books/session.epub"
local SETTINGS_PATH = "/settings/goodreads.lua"

local function goOnline()
  NetworkMgr._wifi_on = true
  NetworkMgr._connected = true
end

local function goOffline()
  NetworkMgr._wifi_on = false
  NetworkMgr._connected = false
end

describe("SyncEngine session-end progress", function()
  local ui, settings, engine, current_page, sent

  -- What's queued for the book, read from the file like the plugin does.
  local function queuedProgress()
    local updates = LuaSettings:open(settings.pending_updates.path):readSetting("updates")
    local update = updates and updates[FILE]
    return update and update.progress and update.progress.value
  end

  local function newEngine()
    local state = { page = nil, pos = nil, search_results = {}, book_status = {} }
    local api = {
      hasCredential = function() return true end,
      findUserBook = function(_, book_id)
        if not NetworkMgr._connected then return {}, "Failed to fetch book" end
        return { id = book_id, book_id = book_id, status_id = GOODREADS.STATUS.READING }
      end,
      updateProgress = function(_, _book_id, value)
        if not NetworkMgr._connected then return nil end
        table.insert(sent, value)
        return { status_id = GOODREADS.STATUS.READING }
      end,
    }
    local wifi = AutoWifi:new { settings = settings, label = "Goodreads" }
    local user = { getId = function() return 1 end }
    local cache = Cache:new { settings = settings, api = api, user = user, state = state, ui = ui }
    -- No mapped page count, so progress is sent as a rounded percentage.
    local page_mapper = {
      cachePageMap = function() end,
      getRemotePagePercent = function(_, page, document_pages) return page / document_pages, nil end,
    }
    local new_engine = SyncEngine:new {
      label = "Goodreads", constants = GOODREADS, highlight_menu_name = "hl_Goodreads",
      api = api, user = user, cache = cache, page_mapper = page_mapper,
      wifi = wifi, dialog_manager = {},
      provider = GoodreadsProvider:new {
        label = "Goodreads",
        api = api, user = user, cache = cache, dialog_manager = {}, page_mapper = page_mapper,
        settings = settings, state = state, ui = ui, wifi = wifi,
      },
      settings = settings, plugin_settings = settings,
      ui = ui, view = {}, state = state,
    }
    cache.provider, cache.wifi = new_engine.provider, wifi
    new_engine:initializePageUpdate()
    return new_engine
  end

  local function openBook(page)
    current_page = page
    ReaderUI.instance = ui
    engine = newEngine()
    engine:onReaderReady()
    UIManager:_runUntil(mocks.Clock.now + 2)
  end

  local function turnTo(page)
    current_page = page
    engine:onPageUpdate(page)
    UIManager:_runUntil(mocks.Clock.now + 2)
  end

  local function sleep()
    engine:onSuspend()
    UIManager:_runUntilIdle()
  end

  -- Like ReaderUI:onClose: CloseDocument while the document is still open,
  -- then the document and reader go away, leaving their scheduled work to run.
  local function closeBook()
    engine:onDocumentClose()
    ui.document = nil
    ReaderUI.instance = nil
    UIManager:_runUntilIdle()
  end

  before_each(function()
    mocks.reset()
    goOnline()
    sent = {}
    ui = {
      document = {
        file = FILE,
        getProps = function() return { title = "Test Book", authors = "Test Author" } end,
        getPageCount = function() return 300 end,
      },
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      getCurrentPage = function() return current_page end,
      doc_settings = nil,
      link = { location_stack = {}, forward_location_stack = {} },
    }
    ui.doc_settings = require("docsettings"):open(FILE)
    settings = GoodreadsSettings:new(SETTINGS_PATH, ui, nil)
    settings:updateBookSetting(FILE, { book_id = "42", pages = 300 })
  end)

  after_each(function()
    UIManager:_runUntilIdle()
  end)

  describe("when turned on", function()
    before_each(function()
      settings:updateSetting(SETTING.SHARED.SYNC_ON_SESSION_END, true)
    end)

    it("sends one final update on close instead of one per threshold crossed", function()
      openBook(60)
      -- Each of these crosses a 10% threshold, so the default mode would
      -- send at each one.
      turnTo(100)
      turnTo(150)
      turnTo(220)
      assert.are.same({}, sent)

      closeBook()
      assert.are.same({ 73 }, sent) -- 220 / 300, rounded
      assert.is_nil(queuedProgress())
    end)

    it("sends progress when the device sleeps, even after only a few pages", function()
      openBook(60)
      turnTo(61) -- well below any page/percentage threshold

      sleep()
      assert.are.same({ 20 }, sent) -- 61 / 300, rounded

      -- Sleeping and then closing must not add a second, duplicate entry.
      closeBook()
      assert.are.same({ 20 }, sent)
    end)

    it("doesn't send anything when no progress was made since the last sync", function()
      openBook(60)
      sleep()
      assert.are.same({}, sent)

      turnTo(61)
      sleep()
      assert.are.same({ 20 }, sent)

      -- No further reading: neither another sleep nor closing adds an entry.
      sleep()
      closeBook()
      assert.are.same({ 20 }, sent)
    end)

    it("doesn't send progress the service already has", function()
      openBook(60)
      -- As if the service already knows about progress further on, e.g. from
      -- another device. Moving local progress back behind it must stay unsent.
      engine.provider.getRemoteProgress = function() return 60 end
      turnTo(100)

      sleep()
      closeBook()
      assert.are.same({}, sent)
    end)

    it("records the final edition page, not just a percentage", function()
      settings:updateSetting(SETTING.SHARED.SYNC_BY_REMOTE_PAGES, true)
      openBook(60)
      -- The linked edition has the same 300 pages, so the mapped page is the
      -- page in the document.
      engine.page_mapper.getRemotePagePercent = function(_, page) return page / 300, page end
      turnTo(65) -- only five pages, well below the page threshold

      sleep()
      assert.are.same({ 65 }, sent)
      closeBook()
      assert.are.same({ 65 }, sent)
    end)

    it("keeps the sleeping position queued while offline, then sends it once on close", function()
      openBook(60)
      goOffline()
      turnTo(61)

      sleep()
      assert.are.same({}, sent)
      assert.equals(20, queuedProgress())

      goOnline()
      closeBook()
      assert.are.same({ 20 }, sent)
      assert.is_nil(queuedProgress())
    end)

    it("records a new position for a new session after waking", function()
      openBook(60)
      turnTo(61)
      sleep()
      assert.are.same({ 20 }, sent)

      turnTo(100)
      sleep()
      assert.are.same({ 20, 33 }, sent)

      closeBook()
      assert.are.same({ 20, 33 }, sent)
    end)

    it("sends where a jump started from, not the page it landed on", function()
      openBook(60)
      turnTo(64)
      -- Following a link saves the page being left to ReaderLink's history.
      table.insert(ui.link.location_stack, { { page = 64 } })
      turnTo(250)

      closeBook()
      assert.are.same({ 21 }, sent) -- page 64, not 250
    end)
  end)

  describe("when turned off", function()
    it("keeps sending at the configured thresholds", function()
      openBook(60)
      turnTo(100)

      closeBook()
      assert.are.same({ 33 }, sent)
    end)
  end)
end)
