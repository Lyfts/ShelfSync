-- A jump, e.g. following a link, a table of contents entry or Go to page,
-- isn't reading up to where it lands (#40). KOReader saves the location it
-- leaves to ReaderLink's location stack before a jump, which is how
-- SyncEngine tells one from a page turn. A jump isn't sent, and closing the
-- book right after one queues the page it started from.

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr, ReaderUI = mocks.UIManager, mocks.NetworkMgr, mocks.ReaderUI

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local GoodreadsProvider = require("shelfsync/lib/goodreads/provider")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local GOODREADS = require("shelfsync/lib/goodreads/constants")

local FILE = "/books/test.epub"
local SETTINGS_PATH = "/settings/goodreads.lua"

local function goOnline()
  NetworkMgr._wifi_on = true
  NetworkMgr._connected = true
end

local function goOffline()
  NetworkMgr._wifi_on = false
  NetworkMgr._connected = false
end

describe("SyncEngine jumps", function()
  local ui, settings, engine, current_page, sent, reflowable

  -- A location as ReaderLink saves it: the view context of a fixed-layout
  -- document, or the xpointer of a reflowable one (here, its page number).
  local function location(page)
    if reflowable then return { xpointer = page } end
    return { { page = page } }
  end

  local function locationPage(saved)
    return saved.xpointer or saved[1].page
  end

  -- What's queued for the book, read from the file like the plugin does.
  local function queuedProgress()
    local updates = LuaSettings:open(settings.pending_updates.path):readSetting("updates")
    local update = updates and updates[FILE]
    return update and update.progress and update.progress.value
  end

  -- Wired up like ShelfSyncApp:_buildEngine, with a 300-page book.
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

  -- Opens the book at `page` and waits for its status lookup.
  -- `save_opening_page` is KOReader's "Add opening page to location history",
  -- saved by ReaderLink once the book is ready.
  local function openBook(page, save_opening_page)
    current_page = page
    ReaderUI.instance = ui
    engine = newEngine()
    engine:onReaderReady()
    if save_opening_page then
      table.insert(ui.link.location_stack, location(page))
    end
    UIManager:_runUntil(mocks.Clock.now + 2)
  end

  -- Like ReaderUI:onClose: CloseDocument while the document is still open,
  -- then the document goes away, leaving the engine's scheduled work to run.
  local function closeBook()
    engine:onDocumentClose()
    ui.document = nil
    ReaderUI.instance = nil
    UIManager:_runUntilIdle()
  end

  -- A page turn, or any other move that doesn't save a location first. Waits
  -- for an update it schedules to be sent.
  local function turnTo(page)
    current_page = page
    engine:onPageUpdate(page)
    UIManager:_runUntil(mocks.Clock.now + 2)
  end

  -- Like following a link: ReaderLink:addCurrentLocationToStack saves the
  -- location it leaves and clears the forward history, then it moves.
  local function jumpTo(page)
    ui.link.forward_location_stack = {}
    table.insert(ui.link.location_stack, location(current_page))
    turnTo(page)
  end

  -- Like ReaderLink:onGoBackLink and onGoForwardLink.
  local function goBack()
    local link = ui.link
    local saved = table.remove(link.location_stack)
    if saved then
      local same_page = locationPage(saved) == current_page
      if #link.forward_location_stack == 0 and not same_page then
        table.insert(link.forward_location_stack, location(current_page))
      end
      if same_page then
        table.insert(link.forward_location_stack, saved)
        saved = table.remove(link.location_stack)
      end
    end
    if saved then
      table.insert(link.forward_location_stack, saved)
      turnTo(locationPage(saved))
    end
  end

  local function goForward()
    local link = ui.link
    local saved = table.remove(link.forward_location_stack)
    if saved and locationPage(saved) == current_page then
      table.insert(link.location_stack, saved)
      saved = table.remove(link.forward_location_stack)
    end
    if saved then
      table.insert(link.location_stack, saved)
      turnTo(locationPage(saved))
    end
  end

  before_each(function()
    mocks.reset()
    goOnline()
    sent = {}
    reflowable = false
    ui = {
      document = {
        file = FILE,
        getProps = function() return { title = "Test Book", authors = "Test Author" } end,
        getPageCount = function() return 300 end,
        getPageFromXPointer = function(_, xpointer) return xpointer end,
        getVisiblePageNumberCount = function() return 1 end,
      },
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      getCurrentPage = function() return current_page end,
      doc_settings = DocSettings:open(FILE),
      link = { location_stack = {}, forward_location_stack = {} },
    }
    settings = GoodreadsSettings:new(SETTINGS_PATH, ui, nil)
    settings:updateBookSetting(FILE, { book_id = "42", pages = 300 })
  end)

  after_each(function()
    UIManager:_runUntilIdle()
  end)

  describe("in progress tracking mode", function()
    before_each(function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
    end)

    it("doesn't send a jump forward across an interval, but sends reading on from there at the next one", function()
      openBook(60)
      turnTo(61)
      assert.are.same({ 20 }, sent)

      jumpTo(231)
      turnTo(232)
      assert.are.same({ 20 }, sent)

      turnTo(240)
      assert.are.same({ 20, 80 }, sent)
    end)

    it("doesn't take going back for a jump, and takes going forward again for one", function()
      openBook(60)
      turnTo(61)
      -- Back to an earlier chapter, then back to where the reader was.
      jumpTo(10)
      goBack()
      assert.are.same({ 20, 20 }, sent)

      jumpTo(231)
      goBack()
      goForward()
      assert.are.equal(231, current_page)
      assert.are.same({ 20, 20 }, sent)
    end)

    it("doesn't take going back to a page that a jump took the reader to for reading", function()
      reflowable = true
      openBook(60)
      turnTo(61)
      jumpTo(231)
      jumpTo(10)
      goBack()
      assert.are.equal(231, current_page)
      assert.are.same({ 20 }, sent)

      goBack()
      turnTo(90)
      assert.are.same({ 20, 30 }, sent)
    end)

    it("doesn't take clearing the location history for going back", function()
      openBook(60)
      turnTo(61)
      jumpTo(239)
      -- Like ReaderLink:onClearLocationStack.
      ui.link.location_stack = {}
      ui.link.forward_location_stack = {}
      turnTo(240)
      assert.are.same({ 20, 80 }, sent)
    end)

    it("doesn't take going back with nowhere to go for going back", function()
      -- With the opening page in the history, going back there doesn't
      -- move, and nor does going back after going forward to it again.
      openBook(239, true)
      goBack()
      turnTo(238)
      goForward()
      assert.are.equal(239, current_page)
      goBack()
      assert.are.equal(239, current_page)

      turnTo(240)
      assert.are.same({ 79, 80 }, sent)
    end)

    it("takes every page update from one jump in fixed-layout scroll mode for the jump", function()
      ui.paging, ui.view = {}, { page_scroll = true }
      goOffline()
      openBook(60)
      turnTo(75)
      -- Building the view after the jump sends several page updates at once.
      table.insert(ui.link.location_stack, location(75))
      for _, page in ipairs({ 232, 231, 231, 232, 231, 231 }) do
        current_page = page
        engine:onPageUpdate(page)
      end
      closeBook()
      assert.are.equal(25, queuedProgress())
    end)

    it("takes in a link followed within the page in scroll mode, which only sends PosUpdate", function()
      openBook(60)
      turnTo(61)
      turnTo(85)
      table.insert(ui.link.location_stack, location(85))
      engine:onPosUpdate(nil, 85)

      current_page = 90
      engine:onPosUpdate(nil, 90)
      UIManager:_runUntil(mocks.Clock.now + 2)
      assert.are.same({ 20, 30 }, sent)
    end)

    it("doesn't take the opening page that KOReader saves to the location history for a jump", function()
      openBook(60, true)
      turnTo(61)
      assert.are.same({ 20 }, sent)
    end)

    it("queues the page a jump started from when the book is closed offline with no page turned since", function()
      openBook(60)
      goOffline()
      turnTo(75)
      jumpTo(231)
      jumpTo(234)
      goBack()
      closeBook()

      assert.are.same({}, sent)
      assert.are.equal(25, queuedProgress())
    end)

    it("tells a jump from a page turn before the book's status is known", function()
      goOffline()
      openBook(60)
      assert.is_falsy(engine.state.process_page_turns)
      turnTo(75)
      jumpTo(231)
      closeBook()

      assert.are.equal(25, queuedProgress())
    end)

    it("takes a page turned after a jump as read", function()
      goOffline()
      openBook(60)
      jumpTo(231)
      turnTo(232)
      closeBook()

      assert.are.equal(77, queuedProgress())
    end)
  end)

  describe("in time tracking mode", function()
    it("keeps the page before a jump for the next periodic update", function()
      openBook(60)
      turnTo(61)
      assert.are.same({ 20 }, sent)

      turnTo(64)
      jumpTo(231)
      UIManager:_runUntil(mocks.Clock.now + 5 * 60)
      assert.are.same({ 20, 21 }, sent)
    end)

    it("doesn't send a jump target when KOReader sends the same page again", function()
      openBook(60)
      turnTo(61)
      turnTo(64)
      jumpTo(231)
      -- e.g. ReaderPaging:onGotoPage sends PageUpdate twice.
      engine:onPageUpdate(231)
      UIManager:_runUntil(mocks.Clock.now + 5 * 60)
      assert.are.same({ 20, 21 }, sent)
    end)

    it("doesn't send a jump target when the book is looked up again after waking, with sync on open", function()
      settings:updateSetting(SETTING.SHARED.SYNC_ON_OPEN, true)
      openBook(60)
      assert.are.same({ 20 }, sent)

      turnTo(64)
      jumpTo(231)
      engine:onSuspend()
      engine:onResume()
      UIManager:_runUntil(mocks.Clock.now + 5)
      assert.are.same({ 20 }, sent)
    end)

    it("keeps a manual update after a jump, instead of sending the page before the jump", function()
      openBook(60)
      turnTo(61)
      turnTo(75)
      jumpTo(231)
      engine:onUpdateProgress(nil, nil, true)
      UIManager:_runUntil(mocks.Clock.now + 5 * 60)
      closeBook()
      assert.are.same({ 20, 77 }, sent)
    end)

    it("doesn't send a page turn after a manual update twice", function()
      openBook(60)
      turnTo(61)
      turnTo(75)
      jumpTo(229)
      engine:onUpdateProgress(nil, nil, true)
      turnTo(230)
      assert.are.same({ 20, 76, 77 }, sent)

      UIManager:_runUntil(mocks.Clock.now + 5 * 60)
      assert.are.same({ 20, 76, 77 }, sent)
    end)

    it("doesn't take going back with nowhere to go for going back with two columns", function()
      -- Two columns, showing one page number.
      reflowable = true
      ui.document.getVisiblePageCount = function() return 2 end
      goOffline()
      openBook(231, true)
      goBack()
      turnTo(230)
      turnTo(229)
      goForward()
      goBack()
      turnTo(230)
      closeBook()
      assert.are.equal(77, queuedProgress())
    end)

    it("sends the page before a jump when the book is closed right after it", function()
      openBook(60)
      turnTo(61)
      turnTo(64)
      jumpTo(231)
      closeBook()

      assert.are.same({ 20, 21 }, sent)
    end)
  end)
end)
