-- Covers updates that can't be sent right away (issue #17): progress for a
-- book read and closed offline, and a "finished" status that failed to send,
-- are kept per book and sent once the network is back -- also from the file
-- browser, where no document is open and provider methods can't fall back to
-- the open document's link, edition or page count.
--
-- On a device, flushes from two plugin instances (a closed reader's and the
-- file browser's) can interleave while a request waits on the network. The
-- specs' Lua can't yield across pcall, so that's simulated by fake requests
-- doing the other instance's work before they return.

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr, ReaderUI = mocks.UIManager, mocks.NetworkMgr, mocks.ReaderUI

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local HardcoverProvider = require("shelfsync/lib/hardcover/provider")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local HardcoverApi = require("shelfsync/lib/hardcover/api")
-- The status-menu tests don't open either progress widget.
package.loaded["ui/widget/spinwidget"] = package.loaded["ui/widget/spinwidget"] or {}
package.loaded["shelfsync/lib/common/ui/update_double_spin_widget"] =
  package.loaded["shelfsync/lib/common/ui/update_double_spin_widget"] or {}
local HardcoverMenu = require("shelfsync/lib/hardcover/menu")
local HARDCOVER_CONST = require("shelfsync/lib/hardcover/constants")
local GoodreadsProvider = require("shelfsync/lib/goodreads/provider")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local GOODREADS_CONST = require("shelfsync/lib/goodreads/constants")
local PageboundProvider = require("shelfsync/lib/pagebound/provider")
local PageboundSettings = require("shelfsync/lib/pagebound/settings")
local PageboundApi = require("shelfsync/lib/pagebound/api")
local PAGEBOUND_CONST = require("shelfsync/lib/pagebound/constants")

local STATUS = HARDCOVER_CONST.STATUS
local FILE, OTHER_FILE, MOVED_FILE = "/books/test.epub", "/books/other.epub", "/books/renamed.epub"
local DAY = 24 * 3600

local function goOnline()
  NetworkMgr._wifi_on = true
  NetworkMgr._connected = true
end

local function goOffline()
  NetworkMgr._wifi_on = false
  NetworkMgr._connected = false
end

-- What's queued for filename, read from the file like the plugin does.
local function pending(settings, filename)
  local updates = LuaSettings:open(settings.pending_updates.path):readSetting("updates")
  return updates and updates[filename or FILE]
end

-- Backdates what's queued for filename by `seconds`.
local function age(settings, filename, seconds)
  local file = LuaSettings:open(settings.pending_updates.path)
  local updates = file:readSetting("updates")
  local update = updates[filename]
  if update.progress then update.progress.queued_at = update.progress.queued_at - seconds end
  if update.finished_at then update.finished_at = update.finished_at - seconds end
  file:saveSetting("updates", updates)
  file:flush()
end

-- As if the last failed try at the date of filename's queued finished status
-- was an hour (or `seconds`) earlier, so it's due another.
local function waitForDateRetry(settings, filename, seconds)
  local file = LuaSettings:open(settings.pending_updates.path)
  local updates = file:readSetting("updates")
  local update = updates[filename or FILE]
  update.date_tried_at = update.date_tried_at - (seconds or 3600)
  file:saveSetting("updates", updates)
  file:flush()
end

local function queue(settings, filename, progress, finished)
  local book = settings:readBookSettings(filename)
  if progress then settings.pending_updates:addProgress(filename, book, progress, "percentage") end
  if finished then settings.pending_updates:addFinished(filename, book) end
end

describe("SyncEngine pending updates", function()
  local document, current_page, shown
  local original_show

  local function newUi(doc)
    return {
      document = doc,
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      getCurrentPage = function() return current_page end,
      -- The same store DocSettings:open() returns once the book is closed.
      doc_settings = doc and DocSettings:open(doc.file),
    }
  end

  -- Wires up an engine like ShelfSyncApp:_buildEngine; one per plugin instance.
  local function newEngine(o)
    local state = { page = nil, pos = nil, search_results = {}, book_status = {} }
    local wifi = AutoWifi:new { settings = o.settings, label = o.label }
    local user = { getId = function() return 1 end }
    local cache = Cache:new { settings = o.settings, api = o.api, user = user, state = state, ui = o.ui }
    local page_mapper = {
      cachePageMap = function() end,
      getRemotePagePercent = function(_, page, document_pages) return page / document_pages, nil end,
    }
    local engine = SyncEngine:new {
      label = o.label,
      constants = o.constants,
      highlight_menu_name = "hl_" .. o.label,
      api = o.api, user = user, cache = cache, page_mapper = page_mapper,
      wifi = wifi, dialog_manager = {},
      provider = o.Provider:new {
        label = o.label,
        api = o.api, user = user, cache = cache, dialog_manager = {}, page_mapper = page_mapper,
        settings = o.settings, state = state, ui = o.ui, wifi = wifi,
      },
      settings = o.settings,
      plugin_settings = o.settings,
      ui = o.ui, view = {}, state = state,
    }
    cache.provider, cache.wifi = engine.provider, wifi
    engine:initializePageUpdate()
    return engine
  end

  before_each(function()
    mocks.reset()
    goOffline()

    shown = {}
    original_show = UIManager.show
    UIManager.show = function(_, widget) table.insert(shown, widget.text) end
    G_reader_settings.readSetting = function(_, key)
      if key == "end_document_action" then return "mark_read" end
    end

    current_page = 1
    document = {
      file = FILE,
      getProps = function() return { title = "Test Book", authors = "Test Author" } end,
      getPageCount = function() return 300 end,
    }
  end)

  after_each(function()
    UIManager.show = original_show
    G_reader_settings.readSetting = nil
  end)

  describe("with Hardcover", function()
    local SETTINGS_PATH = "/settings/hardcover.lua"
    local ui, settings, engine, api, remote, calls, hooks

    local function hardcoverEngine(engine_ui)
      return newEngine {
        label = "Hardcover", constants = HARDCOVER_CONST, Provider = HardcoverProvider,
        settings = HardcoverSettings:new(SETTINGS_PATH, engine_ui, nil), api = api, ui = engine_ui,
      }
    end

    -- A new reader for the book, as KOReader creates one (with its own
    -- plugin instance) each time a book is opened.
    local function openBook()
      ui.document = document
      ReaderUI.instance = ui
      engine = hardcoverEngine(ui)
      engine:onReaderReady()
      UIManager:_runUntil(mocks.Clock.now + 2)
    end

    -- Mirrors ReaderUI:onClose: CloseDocument while the document is still
    -- open, then the document and reader go away, leaving their plugin
    -- instance's scheduled work to run.
    local function closeBook()
      engine:onDocumentClose()
      ui.document = nil
      ReaderUI.instance = nil
      UIManager:_runUntilIdle()
    end

    local function flushFromFileBrowser()
      hardcoverEngine(newUi(nil)):flushPendingUpdates()
      UIManager:_runUntilIdle()
    end

    -- Chooses the status menu item named `name` (after its icon), and confirms it.
    local function chooseFromMenu(name, menu_instance)
      local menu = HardcoverMenu:new {
        api = api, cache = engine.cache, state = engine.state, ui = ui, settings = engine.settings,
        dialog_manager = {
          maybeConfirm = function(_, options) options.ok_callback() end,
          showError = function(_, text) table.insert(shown, text) end,
        },
      }
      for _, item in ipairs(menu:getStatusSubMenuItems()) do
        if item.text and item.text:match("^%S+ (.*)$") == name then
          item.callback(menu_instance or { updateItems = function() end })
          return
        end
      end
      error(name .. " menu item not found")
    end

    local function removeBook()
      chooseFromMenu("Remove")
    end

    local function pagesSent()
      local pages = {}
      for _, call in ipairs(calls.updatePage) do table.insert(pages, call.page) end
      return pages
    end

    -- Runs and clears a one-off hook; returns true if the request should fail.
    local function runHook(name)
      local hook = hooks[name]
      hooks[name] = nil
      return hook and hook()
    end

    before_each(function()
      -- Opened by openBook.
      ui = newUi(document)
      ui.document = nil
      settings = HardcoverSettings:new(SETTINGS_PATH, ui, nil)
      settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, "a-real-token")
      settings:updateBookSetting(FILE, { book_id = 42, edition_id = 7, pages = 300 })
      settings:updateBookSetting(OTHER_FILE, { book_id = 43, edition_id = 9, pages = 300 })

      -- Fake Hardcover account. Like the real API, requests are skipped
      -- without an error while disconnected.
      remote = { id = 99, status_id = STATUS.READING, progress_pages = 20 }
      calls = { findUserBook = {}, updateUserBook = {}, updatePage = {}, removeRead = {} }
      hooks = {}
      local function userBook(book_id)
        if not remote.id then return {} end
        return {
          id = remote.id,
          book_id = book_id,
          status_id = remote.status_id,
          user_book_reads = { { id = 5, progress_pages = remote.progress_pages, started_at = "2026-10-01" } },
        }
      end
      api = setmetatable({
        settings = settings,
        findUserBook = function(_, book_id)
          table.insert(calls.findUserBook, book_id)
          runHook("findUserBook")
          if not NetworkMgr._connected then return {} end
          return userBook(book_id)
        end,
        updateUserBook = function(_, book_id, status_id)
          table.insert(calls.updateUserBook, status_id)
          if runHook("updateUserBook") or not NetworkMgr._connected then return nil end
          remote.id = remote.id or 100
          remote.status_id = status_id
          return userBook(book_id)
        end,
        updatePage = function(_, read_id, edition_id, page)
          table.insert(calls.updatePage, { read_id = read_id, edition_id = edition_id, page = page })
          if runHook("updatePage") or not NetworkMgr._connected then return nil end
          remote.progress_pages = page
          return userBook(42)
        end,
        removeRead = function(_, read_id)
          table.insert(calls.removeRead, read_id)
          if runHook("removeRead") or not NetworkMgr._connected or read_id ~= remote.id then return nil end
          remote.id = nil
          remote.status_id = nil
          return { id = read_id }
        end,
      }, { __index = HardcoverApi })

      engine = hardcoverEngine(ui)
    end)

    it("sends the closing position of a book read offline from the file browser, once the network is back", function()
      openBook()
      assert.is_falsy(engine.state.process_page_turns)

      current_page = 150
      -- Also runs the closed reader's attempt to send it, while still offline.
      closeBook()

      local queued = pending(settings)
      assert.are.equal(42, queued.book_id)
      assert.are.same({ 50, "percentage", 7 },
        { queued.progress.value, queued.progress.update_type, queued.progress.edition_id })
      assert.are.same({}, calls.updatePage)

      goOnline()
      hardcoverEngine(newUi(nil)):onNetworkConnected()
      UIManager:_runUntilIdle()

      -- Edition and page count come from the closed book's own settings.
      assert.are.same({ { read_id = 5, edition_id = 7, page = 150 } }, calls.updatePage)
      assert.is_nil(pending(settings))
    end)

    it("sends what's queued before looking up a book opened offline, once the network is back", function()
      openBook()
      -- Long enough that the lookup when it opened has given up.
      UIManager:_runUntilIdle()
      queue(settings, OTHER_FILE, 50)
      calls.findUserBook = {}

      goOnline()
      engine:onNetworkConnected()
      UIManager:_runUntilIdle()

      assert.are.same({ 43, 42 }, { calls.findUserBook[1], calls.findUserBook[2] })
      assert.is_nil(pending(settings, OTHER_FILE))
    end)

    describe("when the first requests after connecting time out", function()
      local timeouts

      before_each(function()
        timeouts = 0
        local findUserBook = api.findUserBook
        api.findUserBook = function(self, book_id, ...)
          if timeouts > 0 then
            timeouts = timeouts - 1
            table.insert(calls.findUserBook, book_id)
            return {}, { completed = false, request_error = "timeout" }
          end
          return findUserBook(self, book_id, ...)
        end
      end)

      it("tries again a few seconds later", function()
        queue(settings, FILE, 50)
        timeouts = 2

        goOnline()
        hardcoverEngine(newUi(nil)):onNetworkConnected()
        UIManager:_runUntil(mocks.Clock.now + 1)
        assert.are.equal(1, #calls.findUserBook)
        assert.are.equal(50, pending(settings).progress.value)

        UIManager:_runUntilIdle()
        assert.are.equal(3, #calls.findUserBook)
        assert.are.same({ 150 }, pagesSent())
        assert.is_nil(pending(settings))
      end)

      it("keeps what's queued after a few tries", function()
        queue(settings, FILE, 50)
        timeouts = 10

        goOnline()
        local browser = hardcoverEngine(newUi(nil))
        browser:onNetworkConnected()
        UIManager:_runUntilIdle()

        assert.are.equal(4, #calls.findUserBook)
        assert.are.same({}, calls.updatePage)
        assert.are.equal(50, pending(settings).progress.value)

        -- Tried again the next time the network connects.
        timeouts = 0
        browser:onNetworkConnected()
        UIManager:_runUntilIdle()
        assert.are.same({ 150 }, pagesSent())
        assert.is_nil(pending(settings))
      end)

      it("starts over for another NetworkConnected while it's trying, and stops the earlier tries", function()
        queue(settings, FILE, 50)
        timeouts = 10

        goOnline()
        local browser = hardcoverEngine(newUi(nil))
        browser:onNetworkConnected()
        UIManager:_runUntil(mocks.Clock.now + 1)
        browser:onNetworkConnected()
        UIManager:_runUntilIdle()

        -- The first try, then the four of the second NetworkConnected.
        assert.are.equal(5, #calls.findUserBook)
      end)

      it("sends what's queued when the network comes back before the next try", function()
        queue(settings, FILE, 50)
        timeouts = 1

        goOnline()
        local browser = hardcoverEngine(newUi(nil))
        browser:onNetworkConnected()
        UIManager:_runUntil(mocks.Clock.now + 1)
        goOffline()
        UIManager:_runUntil(mocks.Clock.now + 1)
        goOnline()
        browser:onNetworkConnected()
        UIManager:_runUntil(mocks.Clock.now + 1)
        -- Gone again by the time the first NetworkConnected's next try is due.
        goOffline()
        UIManager:_runUntilIdle()

        assert.are.same({ 150 }, pagesSent())
        assert.is_nil(pending(settings))
      end)

      it("doesn't turn Wi-Fi on to try again", function()
        settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
        queue(settings, FILE, 50)
        timeouts = 10
        local restores = 0
        local restoreWifiAsync = NetworkMgr.restoreWifiAsync
        NetworkMgr.restoreWifiAsync = function(...)
          restores = restores + 1
          return restoreWifiAsync(...)
        end
        finally(function() NetworkMgr.restoreWifiAsync = restoreWifiAsync end)

        goOnline()
        hardcoverEngine(newUi(nil)):onNetworkConnected()
        UIManager:_runUntil(mocks.Clock.now + 1)
        goOffline()
        UIManager:_runUntilIdle()

        assert.are.equal(1, #calls.findUserBook)
        assert.are.equal(0, restores)
        assert.are.equal(50, pending(settings).progress.value)
      end)

      it("doesn't try again when ShelfSync turned Wi-Fi on itself", function()
        settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
        NetworkMgr._online = true
        queue(settings, FILE, 50)
        timeouts = 10
        local restores = 0
        local restoreWifiAsync = NetworkMgr.restoreWifiAsync
        NetworkMgr.restoreWifiAsync = function(...)
          restores = restores + 1
          return restoreWifiAsync(...)
        end
        -- On a Kindle, Wi-Fi is still connected for a while after it starts
        -- turning off. Here it's long enough for any retry to run first.
        local turnOffWifi = NetworkMgr.turnOffWifi
        NetworkMgr.turnOffWifi = function(self, cb)
          UIManager:scheduleIn(30, function() turnOffWifi(self, cb) end)
        end
        -- As ShelfSyncApp:onNetworkConnected passes it on.
        local forwarding = true
        UIManager._addListener(function(event)
          if forwarding and event.name == "NetworkConnected" then
            hardcoverEngine(newUi(nil)):onNetworkConnected()
          end
        end)
        finally(function()
          forwarding = false
          NetworkMgr.restoreWifiAsync = restoreWifiAsync
          NetworkMgr.turnOffWifi = turnOffWifi
        end)

        flushFromFileBrowser()

        -- The flush that turned Wi-Fi on, then the one for its NetworkConnected.
        assert.are.equal(2, #calls.findUserBook)
        assert.are.equal(1, restores)
        assert.are.equal(50, pending(settings).progress.value)
      end)

      it("doesn't try again once the network has gone", function()
        queue(settings, FILE, 50)
        timeouts = 1

        goOnline()
        hardcoverEngine(newUi(nil)):onNetworkConnected()
        UIManager:_runUntil(mocks.Clock.now + 1)
        goOffline()
        UIManager:_runUntilIdle()

        assert.are.equal(1, #calls.findUserBook)
        assert.are.equal(50, pending(settings).progress.value)
      end)
    end)

    it("sends the position a book was closed at once it has closed", function()
      goOnline()
      openBook()
      assert.is_true(engine.state.process_page_turns)

      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      assert.are.same({ 30 }, pagesSent())

      -- Throttled until a few minutes from now, but the book's closed first.
      current_page = 150
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 30, 150 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("cancels an earlier live position when the book closes before it is sent", function()
      goOnline()
      openBook()

      current_page = 30
      engine:onPageUpdate(current_page)
      current_page = 150
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 150 }, pagesSent())
      assert.are.equal(150, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("keeps the closing position queued while a live update is being sent", function()
      goOnline()
      openBook()

      hooks.updatePage = function()
        current_page = 150
        engine:onDocumentClose()
        ui.document = nil
        ReaderUI.instance = nil
      end
      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.same({ 30, 150 }, pagesSent())
      assert.are.equal(150, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("keeps the newer closing position when an earlier live update fails offline", function()
      goOnline()
      openBook()

      hooks.updatePage = function()
        current_page = 150
        engine:onDocumentClose()
        ui.document = nil
        ReaderUI.instance = nil
        goOffline()
      end
      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.same({ 30 }, pagesSent())
      assert.is_table(pending(settings))
      assert.are.equal(50, pending(settings).progress.value)

      goOnline()
      flushFromFileBrowser()

      assert.are.equal(150, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("doesn't queue a failed live update under a book linked while the request was running", function()
      goOnline()
      openBook()

      hooks.updatePage = function()
        settings:updateBookSetting(FILE, { book_id = 43 })
        goOffline()
      end
      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.same({ 30 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("doesn't cache an old book's successful live response or suppress the new book's closing position", function()
      goOnline()
      openBook()

      hooks.updatePage = function()
        settings:updateBookSetting(FILE, { book_id = 43 })
        engine.cache:cacheUserBook()
      end
      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.equal(43, engine.state.book_status.book_id)
      assert.is_nil(engine.state.synced_progress)

      goOffline()
      closeBook()

      assert.is_table(pending(settings))
      assert.are.equal(43, pending(settings).book_id)
      assert.are.equal(50, pending(settings).progress.value)
    end)

    it("queues the closing position for a book relinked since its progress was sent", function()
      goOnline()
      openBook()

      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      assert.are.same({ 150 }, pagesSent())

      settings:updateBookSetting(FILE, { book_id = 43 })
      goOffline()
      closeBook()

      assert.are.equal(43, pending(settings).book_id)
      assert.are.equal(50, pending(settings).progress.value)
    end)

    it("in progress tracking mode, queues the closing position for a book relinked since its progress was sent", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      current_page = 90
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      assert.are.same({ 90 }, pagesSent())

      settings:updateBookSetting(FILE, { book_id = 43 })
      current_page = 100
      engine:onPageUpdate(current_page)
      goOffline()
      closeBook()

      assert.are.equal(43, pending(settings).book_id)
      assert.are.equal(33, pending(settings).progress.value)
    end)

    it("sends a newly opened reader's live position after an older queued request finishes", function()
      queue(settings, FILE, 10)
      local tracking_during_request
      hooks.updatePage = function()
        openBook()
        tracking_during_request = engine.state.process_page_turns
      end

      goOnline()
      flushFromFileBrowser()
      -- The new reader's status lookup waited for the queued request.
      assert.is_falsy(tracking_during_request)
      assert.is_true(engine.state.process_page_turns)

      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.same({ 30, 150 }, pagesSent())
      assert.are.equal(150, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("looks up the open book's status on reconnect after its queued finished status is sent", function()
      remote.id, remote.status_id = nil, nil
      openBook()
      UIManager:_runUntilIdle()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)

      -- Gives the read cache's lookup, started by the same reconnect, time
      -- to run while the finished status is being sent.
      hooks.updateUserBook = function() UIManager:_runUntil(mocks.Clock.now + 30) end
      goOnline()
      engine:onNetworkConnected()
      UIManager:_runUntilIdle()

      -- Not added back as Currently Reading by the lookup's automatic status.
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.are.equal(STATUS.FINISHED, engine.state.book_status.status_id)
      assert.is_nil(pending(settings))
    end)

    it("doesn't add the open book back as Currently Reading when its status reads back empty after its queued finished status is sent", function()
      remote.id, remote.status_id = nil, nil
      openBook()
      UIManager:_runUntilIdle()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)

      -- Reads lag the write, as Fable's can.
      local lagging = 0
      local findUserBook = api.findUserBook
      api.findUserBook = function(...)
        local result = findUserBook(...)
        if lagging > 0 then
          lagging = lagging - 1
          return {}
        end
        return result
      end
      hooks.updateUserBook = function()
        lagging = 3
        UIManager:_runUntil(mocks.Clock.now + 30)
      end
      goOnline()
      engine:onNetworkConnected()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.are.equal(STATUS.FINISHED, engine.state.book_status.status_id)
    end)

    it("doesn't add a finished book as Currently Reading when it's opened while the file browser sends its queued finished status", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)

      -- Reads lag the write, as Fable's can.
      local lagging = 0
      local findUserBook = api.findUserBook
      api.findUserBook = function(...)
        local result = findUserBook(...)
        if lagging > 0 then
          lagging = lagging - 1
          return {}
        end
        return result
      end
      hooks.updateUserBook = function()
        lagging = 3
        openBook()
      end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("completes a manual update cancelled while Wi-Fi is being restored", function()
      goOnline()
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
      goOffline()

      current_page = 150
      engine.state.page = current_page
      local completions, result, reason = 0
      engine:onUpdateProgress(function(saved, err)
        completions, result, reason = completions + 1, saved, err
      end, true, true)
      assert.are.equal(0, completions)

      engine:onSuspend()
      UIManager:_runUntilIdle()
      engine:cancelPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.equal(1, completions)
      assert.is_nil(result)
      assert.is_string(reason)
      assert.are.same({}, calls.updatePage)
    end)

    it("in progress tracking mode, only queues a closing position further than the book was opened at", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)

      current_page = 180
      openBook()
      current_page = 15
      closeBook()
      assert.is_nil(pending(settings))

      openBook()
      current_page = 180
      closeBook()
      assert.are.equal(60, pending(settings).progress.value)
    end)

    it("in progress tracking mode, doesn't queue a closing position between intervals once one was sent", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      current_page = 54
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 30 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("in progress tracking mode, queues an interval crossing that closing cancels", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      assert.are.same({ 30 }, pagesSent())

      -- Crosses 20%, but the book's closed before that's sent.
      current_page = 66
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 30, 66 }, pagesSent())
      assert.are.equal(66, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("in progress tracking mode, queues where it was left off if nothing was sent, even after a crossing failed", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      hooks.updatePage = function() return true end
      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      current_page = 54
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 30, 54 }, pagesSent())
      assert.are.equal(54, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("in progress tracking mode, queues an interval crossing cancelled by a suspend when the book is closed", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      -- Crosses 30%, but the device suspends before that's sent.
      current_page = 90
      engine:onPageUpdate(current_page)
      engine:onSuspend()
      UIManager:_runUntil(mocks.Clock.now + 2)
      assert.are.same({ 30 }, pagesSent())

      -- No interval crossed since.
      current_page = 93
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 30, 90 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("in progress tracking mode, doesn't send a crossing again on close when a suspend came while it was being sent", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      -- Crosses 30%, and the device suspends while that's being sent.
      hooks.updatePage = function() engine:onSuspend() end
      current_page = 90
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      current_page = 93
      engine:onPageUpdate(current_page)
      closeBook()

      assert.are.same({ 30, 90 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("doesn't send progress again on close when a suspend came while it was being sent", function()
      goOnline()
      openBook()

      hooks.updatePage = function() engine:onSuspend() end
      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)
      closeBook()

      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("in progress tracking mode, doesn't queue a crossing that failed before a later manual update was sent", function()
      settings:updateSetting(SETTING.SHARED.TRACK_METHOD, SETTING.TRACK.PROGRESS)
      goOnline()
      openBook()

      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      -- Crosses 20%, but that's rejected.
      hooks.updatePage = function() return true end
      current_page = 66
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      current_page = 75
      engine:onPageUpdate(current_page)
      engine:updatePageNow(function() end)
      UIManager:_runUntil(mocks.Clock.now + 2)

      -- Not queued at all, as without remote progress to compare against
      -- (Goodreads, Fable), it would be sent.
      current_page = 80
      engine:onPageUpdate(current_page)
      engine:onDocumentClose()

      assert.are.same({ 30, 66, 75 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("sends the closing position once when it's the one being sent as the book closes", function()
      goOnline()
      openBook()

      hooks.updatePage = function()
        engine:onDocumentClose()
        ui.document = nil
        ReaderUI.instance = nil
      end
      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.same({ 30 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("queues a background update when Wi-Fi is restored but never gets online", function()
      goOnline()
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
      goOffline()
      NetworkMgr._never_online = true

      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 120)

      assert.are.same({}, pagesSent())
      assert.are.equal(50, pending(settings).progress.value)
    end)

    it("doesn't queue the closing position of a book that isn't being read there", function()
      openBook()
      engine.state.book_status = { id = 99, status_id = STATUS.TO_READ }
      current_page = 150
      closeBook()

      assert.is_nil(pending(settings))
    end)

    it("queues the closing position of a book whose status couldn't be read again offline", function()
      goOnline()
      openBook()
      assert.is_true(engine.state.process_page_turns)
      goOffline()
      -- As opening the status menu offline does.
      engine.cache:cacheUserBook()
      assert.is_nil(engine.state.book_status.status_id)

      current_page = 150
      closeBook()
      assert.are.equal(50, pending(settings).progress.value)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("doesn't queue the closing position of a book removed through the menu", function()
      goOnline()
      openBook()
      removeBook()
      UIManager:_runUntilIdle()
      assert.are.same({ 99 }, calls.removeRead)

      goOffline()
      current_page = 150
      closeBook()

      assert.is_nil(pending(settings))
    end)

    it("keeps a finished status that couldn't be sent, along with the closing position", function()
      openBook()
      current_page = 300
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      engine:onEndOfBook()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({}, shown)
      assert.is_number(pending(settings).finished_at)

      closeBook()
      assert.is_number(pending(settings).finished_at)
      assert.are.equal(100, pending(settings).progress.value)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ 300 }, pagesSent())
      assert.are.same({ STATUS.FINISHED, STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("keeps the time a finished status was first queued when it's queued again", function()
      openBook()
      current_page = 300
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      engine:onEndOfBook()
      UIManager:_runUntilIdle()
      age(settings, FILE, DAY)
      local finished_at = pending(settings).finished_at

      -- e.g. turning past the last page again
      engine:onEndOfBook()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED, STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(finished_at, pending(settings).finished_at)
    end)

    for _, action in ipairs({ "mark_read", "pop-up" }) do
      it("dates a finished status queued as Wi-Fi couldn't be restored when the book was finished (" .. action .. ")", function()
        local os_time, hasSidecarFile = os.time, DocSettings.hasSidecarFile
        finally(function() os.time, DocSettings.hasSidecarFile = os_time, hasSidecarFile end)
        local start = os_time()
        os.time = function(date) return date and os_time(date) or start + mocks.Clock.now end
        DocSettings.hasSidecarFile = function() return true end
        G_reader_settings.readSetting = function(_, key)
          if key == "end_document_action" then return action end
        end

        goOnline()
        openBook()
        engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
        goOffline()
        NetworkMgr._never_online = true
        current_page = 300
        ui.doc_settings:saveSetting("summary", { status = "complete" })

        local finished_at = os.time()
        engine:onEndOfBook()
        UIManager:_runUntilIdle()

        -- Not when restoring Wi-Fi gave up.
        assert.is_true(os.time() - finished_at > 45)
        assert.are.equal(finished_at, pending(settings).finished_at)
      end)
    end

    it("reports a finished status as saved only once it was", function()
      goOnline()
      openBook()

      engine:onEndOfBook()
      UIManager:_runUntilIdle()

      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.are.same({ "Hardcover status saved" }, shown)
      assert.is_nil(pending(settings))
    end)

    it("doesn't queue a failed finished update under a book linked while the request was running", function()
      goOnline()
      openBook()
      hooks.updateUserBook = function()
        settings:updateBookSetting(FILE, { book_id = 43 })
        return true
      end

      engine:onEndOfBook()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
      assert.are.same({}, shown)
    end)

    it("doesn't send an automatic finished update after sync is disabled while it awaits another write", function()
      goOnline()
      openBook()
      queue(settings, OTHER_FILE, 50)
      local saved
      hooks.updatePage = function()
        engine:_saveBookStatus(FILE, STATUS.FINISHED, function(result) saved = result end)
        settings:updateBookSetting(FILE, { sync = false })
      end

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_false(saved)
      assert.is_nil(pending(settings))
    end)

    it("replaces a queued finished status with one set since", function()
      queue(settings, FILE, 50, true)
      goOnline()

      local saved
      engine.cache:queueBookStatus(FILE, STATUS.READING, function(result) saved = result end)
      UIManager:_runUntilIdle()

      assert.is_true(saved)
      assert.is_nil(pending(settings).finished_at)
      assert.are.equal(50, pending(settings).progress.value)
    end)

    it("drops a queued finished status when another status is chosen from the menu, even if that can't be sent", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)

      local saved
      engine.cache:queueBookStatus(FILE, STATUS.READING, function(result) saved = result end)
      UIManager:_runUntilIdle()

      assert.is_false(saved)
      assert.is_nil(pending(settings).finished_at)
      assert.are.equal(50, pending(settings).progress.value)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ STATUS.READING }, calls.updateUserBook)
      assert.are.same({ 150 }, pagesSent())
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("drops a moved book's queued finished status when another status is chosen from the menu", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      mocks.moveBook(FILE, MOVED_FILE)
      document.file = MOVED_FILE
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)

      chooseFromMenu(HARDCOVER_CONST.STATUS_NAME[STATUS.READING])
      UIManager:_runUntilIdle()
      goOnline()
      flushFromFileBrowser()

      assert.are.same({ STATUS.READING }, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_nil(pending(settings, FILE))
    end)

    it("finishes a queued status write before a newer manual status and its continuation", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      local completed, cached_at_refresh = {}, nil
      local updateUserBook = api.updateUserBook
      api.updateUserBook = function(self, ...)
        local result = updateUserBook(self, ...)
        if result then table.insert(completed, result.status_id) end
        return result
      end
      hooks.updateUserBook = function()
        engine.cache:queueBookStatus(FILE, STATUS.READING, function(saved)
          if saved then cached_at_refresh = engine.state.book_status.status_id end
          table.insert(completed, "refreshed")
        end)
      end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ STATUS.FINISHED, STATUS.READING, "refreshed" }, completed)
      assert.are.equal(STATUS.READING, cached_at_refresh)
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("keeps a queued finished status when the book's visibility is changed", function()
      goOnline()
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)

      -- Sends the status the book has there as Private.
      engine.provider:changeBookVisibility(HARDCOVER_CONST.PRIVACY.PRIVATE)
      UIManager:_runUntilIdle()
      assert.is_table(pending(settings))
      assert.is_number(pending(settings).finished_at)

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.READING, STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("keeps a queued finished status when a visibility change is requested during its write", function()
      goOnline()
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      local privacy
      local updateUserBook = api.updateUserBook
      api.updateUserBook = function(self, book_id, status_id, privacy_setting_id)
        local result = updateUserBook(self, book_id, status_id)
        if privacy_setting_id then privacy = privacy_setting_id end
        return result
      end
      hooks.updateUserBook = function()
        engine.provider:changeBookVisibility(HARDCOVER_CONST.PRIVACY.PRIVATE)
      end

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED, STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(HARDCOVER_CONST.PRIVACY.PRIVATE, privacy)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.are.equal(STATUS.FINISHED, engine.state.book_status.status_id)
      assert.is_nil(pending(settings))
    end)

    it("still changes the book's visibility if it's closed while another update is being sent", function()
      goOnline()
      openBook()
      local privacy
      local updateUserBook = api.updateUserBook
      api.updateUserBook = function(self, book_id, status_id, privacy_setting_id)
        privacy = privacy_setting_id
        return updateUserBook(self, book_id, status_id)
      end
      queue(settings, OTHER_FILE, 50)
      hooks.findUserBook = function()
        engine.provider:changeBookVisibility(HARDCOVER_CONST.PRIVACY.PRIVATE)
        engine:onDocumentClose()
        ui.document = nil
        ReaderUI.instance = nil
      end

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ 150 }, pagesSent())
      assert.are.same({ STATUS.READING }, calls.updateUserBook)
      assert.are.equal(HARDCOVER_CONST.PRIVACY.PRIVATE, privacy)
      assert.are.same({}, shown)
    end)

    it("removes pending progress and finished status when the book is removed through the menu", function()
      goOnline()
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)

      removeBook()
      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ 99 }, calls.removeRead)
      assert.are.same({}, calls.updateUserBook)
      assert.is_nil(remote.status_id)
      assert.are.same({}, engine.state.book_status)
      assert.is_nil(pending(settings))
    end)

    it("removes the book after a queued finished write that was already in flight", function()
      goOnline()
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      hooks.updateUserBook = removeBook

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({ 99 }, calls.removeRead)
      assert.is_nil(remote.status_id)
      assert.are.same({}, engine.state.book_status)
      assert.is_nil(pending(settings))
    end)

    it("removes the recreated library entry when Reading is queued between removals across reader instances", function()
      goOnline()
      openBook()
      hooks.removeRead = function()
        engine.cache:queueBookStatus(FILE, STATUS.READING)
        closeBook()
        openBook()
        removeBook()
      end

      removeBook()
      UIManager:_runUntilIdle()

      assert.are.same({ 99, 100 }, calls.removeRead)
      assert.is_nil(remote.id)
      assert.is_nil(remote.status_id)
      assert.are.same({}, engine.state.book_status)
    end)

    it("drops pending updates when the book is removed through the menu, even if that fails", function()
      goOnline()
      openBook()
      goOffline()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)

      removeBook()
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.removeRead)
      assert.are.equal(STATUS.READING, engine.state.book_status.status_id)
      assert.are.same({ "Book status could not be removed" }, shown)
      assert.is_nil(pending(settings))

      goOnline()
      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
    end)

    it("drops a moved book's queued finished status when it's removed through the menu", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      mocks.moveBook(FILE, MOVED_FILE)
      document.file = MOVED_FILE
      openBook()
      goOnline()

      removeBook()
      UIManager:_runUntilIdle()
      flushFromFileBrowser()

      assert.are.same({ 99 }, calls.removeRead)
      assert.are.same({}, calls.updateUserBook)
      assert.is_nil(remote.status_id)
      assert.is_nil(pending(settings, FILE))
    end)

    it("says when a status chosen from the menu couldn't be set", function()
      goOnline()
      openBook()
      goOffline()

      chooseFromMenu(HARDCOVER_CONST.STATUS_NAME[STATUS.FINISHED])
      UIManager:_runUntilIdle()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({ "Book status could not be updated" }, shown)
      assert.is_nil(pending(settings))
    end)

    it("refreshes the status menu once a status is set, unless another menu was opened in the meantime", function()
      goOnline()
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
      goOffline()
      local status_items = {}
      local menu_instance = { item_table = status_items, updateItems = function() end }

      chooseFromMenu(HARDCOVER_CONST.STATUS_NAME[STATUS.FINISHED], menu_instance)
      UIManager:_runUntilIdle()
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.are_not.equal(status_items, menu_instance.item_table)

      -- e.g. back up to the parent menu while Wi-Fi is being restored
      goOffline()
      local other_items = {}
      chooseFromMenu(HARDCOVER_CONST.STATUS_NAME[STATUS.READING], menu_instance)
      menu_instance.item_table = other_items
      UIManager:_runUntilIdle()
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.are.equal(other_items, menu_instance.item_table)

      goOffline()
      menu_instance.item_table = status_items
      chooseFromMenu("Remove", menu_instance)
      menu_instance.item_table = other_items
      UIManager:_runUntilIdle()
      assert.is_nil(remote.status_id)
      assert.are.equal(other_items, menu_instance.item_table)
    end)

    it("doesn't send live progress allowed before a removal that took its turn first", function()
      goOnline()
      openBook()
      queue(settings, OTHER_FILE, 50)
      hooks.updatePage = function()
        -- While that's being sent, the book's removed through the menu, and
        -- then its page is sent while it still has its old status.
        removeBook()
        current_page = 60
        engine.state.page = current_page
        engine:updatePageNow()
      end

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ 99 }, calls.removeRead)
      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(remote.status_id)
      assert.are.same({}, engine.state.book_status)
    end)

    it("doesn't send a background position behind a manual update that took its turn first", function()
      goOnline()
      openBook()

      -- Sent a second from now.
      current_page = 90
      engine:onPageUpdate(current_page)
      current_page = 240
      engine.state.page = current_page
      engine:updatePageNow(function() end)
      UIManager:_runUntilIdle()

      assert.are.same({ 240 }, pagesSent())
      assert.are.equal(240, remote.progress_pages)
    end)

    it("doesn't send a background position behind a manual update that took its turn first, "
        .. "even without remote progress to compare against", function()
      goOnline()
      openBook()
      -- As on Goodreads and Fable.
      engine.provider.getRemoteProgress = function() return 0 end

      current_page = 90
      engine:onPageUpdate(current_page)
      current_page = 240
      engine.state.page = current_page
      engine:updatePageNow(function() end)
      UIManager:_runUntilIdle()

      assert.are.same({ 240 }, pagesSent())
    end)

    it("sends a review for its book even if that's closed while Wi-Fi is being restored to send it", function()
      goOnline()
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
      goOffline()
      local reviewed
      api.updateReview = function(_, user_book_id, rating, text)
        reviewed = { user_book_id, rating, text }
        return {}
      end

      -- As ReviewMenu:_submit sends it.
      engine.cache:serializeUpdate(function()
        engine.provider:submitReview(FILE, 4, "Worth reading")
      end)
      UIManager:_runUntil(mocks.Clock.now + 0.5)
      closeBook()

      assert.are.same({ 99, 4, "Worth reading" }, reviewed)
    end)

    it("holds Wi-Fi until a flush queued behind a manual status has finished", function()
      queue(settings, FILE, 50)
      goOnline()

      -- Another provider restored Wi-Fi and still owns one lease. The fake
      -- request releases it while the manual status is awaiting its response.
      local leases = 1
      local function release()
        leases = leases - 1
        if leases == 0 then goOffline() end
      end
      engine.wifi.withWifi = function(_, callback)
        leases = leases + 1
        callback(true)
        release()
      end
      hooks.updateUserBook = function()
        engine:flushPendingUpdates()
        release()
      end

      local saved
      engine.cache:queueBookStatus(FILE, STATUS.READING, function(result) saved = result end)
      UIManager:_runUntilIdle()

      assert.is_true(saved)
      assert.are.same({ 150 }, pagesSent())
      assert.are.equal(150, remote.progress_pages)
      assert.is_nil(pending(settings))
      assert.are.equal(0, leases)
      assert.is_false(NetworkMgr:isConnected())
    end)

    it("doesn't send a queued finished status once the book is marked as reading again", function()
      queue(settings, FILE, nil, true)
      ui.doc_settings:saveSetting("summary", { status = "reading" })

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("drops a queued finished status as soon as KOReader marks the book as reading again, even offline", function()
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      engine:onEndOfBook()
      closeBook()
      age(settings, FILE, DAY)
      local finished_at = pending(settings).finished_at

      -- From the file browser, on KOReader up to v2024.11.
      DocSettings:open(FILE):saveSetting("summary", { status = "reading" })
      hardcoverEngine(newUi(nil)):onDocSettingsItemsChanged(FILE, { summary = { status = "reading" } })
      UIManager:_runUntilIdle()
      assert.is_nil(pending(settings) and pending(settings).finished_at)

      -- So finishing it again is dated then.
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      engine:onEndOfBook()
      UIManager:_runUntilIdle()
      assert.is_true(pending(settings).finished_at > finished_at)
    end)

    it("drops a moved book's queued finished status when KOReader marks it as reading again", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      mocks.moveBook(FILE, MOVED_FILE)

      -- From the file browser, on KOReader up to v2024.11.
      DocSettings:open(MOVED_FILE):saveSetting("summary", { status = "reading" })
      hardcoverEngine(newUi(nil)):onDocSettingsItemsChanged(MOVED_FILE, { summary = { status = "reading" } })
      UIManager:_runUntilIdle()
      goOnline()
      flushFromFileBrowser()

      -- Only the attempt to set Currently Reading offline.
      assert.are.same({ STATUS.READING }, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_nil(pending(settings, FILE))
    end)

    it("doesn't send a queued finished status once the book is reopened and marked as reading, before that's saved", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      -- A reader keeps the book's settings in memory, and KOReader's "Mark as
      -- reading" only changes them there.
      hooks.findUserBook = function()
        local reader = newUi(document)
        reader.doc_settings = mocks.makeStore()
        for key, value in pairs(DocSettings:open(FILE)._data) do reader.doc_settings:saveSetting(key, value) end
        reader.doc_settings:saveSetting("summary", { status = "reading" })
        ReaderUI.instance = reader
      end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("drops queued updates as soon as sync is disabled or the book is unlinked, even if restored before flushing", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      goOnline()

      queue(settings, FILE, 50, true)
      settings:updateBookSetting(FILE, { sync = false })
      assert.is_nil(pending(settings))
      settings:updateBookSetting(FILE, { sync = true })
      flushFromFileBrowser()
      assert.is_nil(pending(settings))

      queue(settings, FILE, 50, true)
      settings:updateBookSetting(FILE, { _delete = { "book_id", "edition_id", "pages" } })
      assert.is_nil(pending(settings))
      settings:updateBookSetting(FILE, { book_id = 42, edition_id = 7, pages = 300 })
      flushFromFileBrowser()
      assert.is_nil(pending(settings))

      assert.are.same({}, calls.findUserBook)
    end)

    it("doesn't send an update for a book relinked while its remote status is fetched", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      hooks.findUserBook = function()
        settings:updateBookSetting(FILE, { book_id = 44, edition_id = 8 })
      end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.same({}, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("rechecks the edition while fetching remote status, keeping only the finished update", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      hooks.findUserBook = function()
        settings:updateBookSetting(FILE, { edition_id = 8 })
      end

      goOnline()
      flushFromFileBrowser()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("doesn't send an update after sync is disabled while fetching remote status", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      hooks.findUserBook = function()
        settings:updateBookSetting(FILE, { sync = false })
      end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.same({}, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("stops sending when the provider is disabled while fetching remote status, until it's enabled again", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      local browser = hardcoverEngine(newUi(nil))
      browser.settings:subscribe(function(...) browser:onSettingsChanged(...) end)
      hooks.findUserBook = function()
        browser.settings:setProviderEnabled(false)
      end

      goOnline()
      browser:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.updatePage)
      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(50, pending(settings).progress.value)
      assert.is_number(pending(settings).finished_at)

      browser.settings:setProviderEnabled(true)
      browser:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ 150 }, pagesSent())
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("stops a closed reader sending once the provider's turned off in the file browser", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      -- The file browser has its own plugin instance, and settings.
      hooks.findUserBook = function()
        HardcoverSettings:new(SETTINGS_PATH, newUi(nil), nil):setProviderEnabled(false)
      end

      goOnline()
      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.updatePage)
      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(50, pending(settings).progress.value)
      assert.is_number(pending(settings).finished_at)
    end)

    it("doesn't send a closed reader's finished status once the provider's turned off in the file browser", function()
      goOnline()
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
      goOffline()
      ui.doc_settings:saveSetting("summary", { status = "complete" })

      -- Turned off before Wi-Fi is back to send it.
      engine:onEndOfBook()
      engine:onDocumentClose()
      ui.document = nil
      ReaderUI.instance = nil
      HardcoverSettings:new(SETTINGS_PATH, newUi(nil), nil):setProviderEnabled(false)
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.updateUserBook)
      assert.are.equal(STATUS.READING, remote.status_id)
    end)

    it("doesn't send updates cancelled while fetching remote status", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      hooks.findUserBook = function()
        settings.pending_updates:clearProgress(FILE)
        settings.pending_updates:clearFinished(FILE)
      end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.same({}, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("keeps a queued finished status, but not progress, when the book's linked to another edition", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      settings:updateBookSetting(FILE, { edition_id = 8 })

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("still sends a queued finished status, but not progress, for a book that's been moved or deleted", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 100, true)
      queue(settings, OTHER_FILE, 50)
      -- Their settings, and so their links, go with them.
      mocks.moveBook(FILE, "/books/read/test.epub")
      mocks.deleteBook(OTHER_FILE)

      -- Their own sync setting can't be checked any more.
      local browser = hardcoverEngine(newUi(nil))
      browser.settings:subscribe(function(...) browser:onSettingsChanged(...) end)
      browser.settings:updateSetting(SETTING.SHARED.ALWAYS_SYNC, true)

      goOnline()
      browser:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ 42 }, calls.findUserBook)
      assert.are.same({}, calls.updatePage)
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings, FILE))
      assert.is_nil(pending(settings, OTHER_FILE))
    end)

    it("still sends the finished status of a book deleted while Wi-Fi is being restored to send it", function()
      goOnline()
      openBook()
      engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)
      goOffline()
      current_page = 300
      ui.doc_settings:saveSetting("summary", { status = "complete" })

      -- As the "Delete file" end-of-book action does, before Wi-Fi is back.
      engine:onEndOfBook()
      engine:onDocumentClose()
      ui.document = nil
      ReaderUI.instance = nil
      mocks.deleteBook(FILE)
      UIManager:_runUntilIdle()

      assert.are.same({}, calls.updatePage)
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("still sends the finished status of a book deleted while an earlier update is being sent", function()
      goOnline()
      openBook()
      hooks.updatePage = function()
        current_page = 300
        ui.doc_settings:saveSetting("summary", { status = "complete" })
        engine:onEndOfBook()
        engine:onDocumentClose()
        ui.document = nil
        ReaderUI.instance = nil
        mocks.deleteBook(FILE)
      end
      current_page = 30
      engine:onPageUpdate(current_page)
      UIManager:_runUntilIdle()

      assert.are.same({ 30 }, pagesSent())
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings))
    end)

    it("drops queued progress that's behind the remote", function()
      remote.progress_pages = 240
      queue(settings, FILE, 50)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.equal(240, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("drops queued progress for a book that isn't being read there", function()
      remote.status_id = STATUS.TO_READ
      queue(settings, FILE, 50)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.is_nil(pending(settings))
    end)

    it("drops queued progress for a book that has no status there", function()
      remote.id, remote.status_id = nil, nil
      queue(settings, FILE, 50)

      goOnline()
      flushFromFileBrowser()
      flushFromFileBrowser()

      assert.are.same({ 42 }, calls.findUserBook)
      assert.are.same({}, calls.updatePage)
      assert.is_nil(pending(settings))
    end)

    it("drops queued progress that can't be converted without a page count, rather than retrying it", function()
      settings:updateBookSetting(FILE, { _delete = { "pages" } })
      queue(settings, FILE, 50)

      goOnline()
      flushFromFileBrowser()
      flushFromFileBrowser()

      assert.are.same({ 42 }, calls.findUserBook)
      assert.are.same({}, calls.updatePage)
      assert.is_nil(pending(settings))
    end)

    it("drops updates queued more than 4 weeks ago", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      age(settings, FILE, 29 * DAY)
      queue(settings, OTHER_FILE, 50)
      age(settings, OTHER_FILE, 14 * DAY)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ 43 }, calls.findUserBook)
      assert.are.same({ 150 }, pagesSent())
      assert.are.same({}, calls.updateUserBook)
      assert.is_nil(pending(settings, FILE))
      assert.is_nil(pending(settings, OTHER_FILE))
    end)

    it("leaves the open book's queued progress to live tracking", function()
      queue(settings, FILE, 30)

      goOnline()
      openBook()
      engine:onNetworkConnected()
      UIManager:_runUntil(mocks.Clock.now + 2)

      assert.is_true(engine.state.process_page_turns)
      assert.are.same({}, calls.updatePage)
      assert.are.equal(30, pending(settings).progress.value)

      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(pending(settings))

      -- Already sent: nothing left to queue on close.
      closeBook()
      assert.is_nil(pending(settings))
      assert.are.same({ 150 }, pagesSent())
    end)

    it("sends the open book's queued progress once it closes, even where it was opened", function()
      openBook()
      current_page = 150
      closeBook()
      assert.are.equal(50, pending(settings).progress.value)

      openBook()
      goOnline()
      engine:onNetworkConnected()
      UIManager:_runUntilIdle()
      assert.are.same({}, calls.updatePage)

      closeBook()

      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("queues a background update that fails after the network drops, but not a manual one", function()
      goOnline()
      openBook()
      assert.is_true(engine.state.process_page_turns)

      goOffline()
      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      assert.are.same({ 150 }, pagesSent())
      assert.are.equal(50, pending(settings).progress.value)

      settings.pending_updates:clearProgress(FILE)
      local result
      engine:onUpdateProgress(function(r) result = r end, true)
      UIManager:_runUntil(mocks.Clock.now + 2)

      assert.are.same({ 150, 150 }, pagesSent())
      assert.is_nil(result)
      assert.is_nil(pending(settings))
    end)

    it("doesn't queue a background update that's rejected while connected", function()
      goOnline()
      openBook()

      hooks.updatePage = function() return true end
      current_page = 150
      engine:onPageUpdate(current_page)
      UIManager:_runUntil(mocks.Clock.now + 2)

      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("still closes the book when its closing position can't be queued", function()
      openBook()
      engine.page_mapper.getRemotePagePercent = function() error("no page map") end
      current_page = 150

      assert.has_no.errors(closeBook)
      assert.is_nil(pending(settings))
    end)

    it("keeps queued updates, and stops sending, when the network goes during a flush", function()
      queue(settings, FILE, 50)
      queue(settings, OTHER_FILE, 50)

      goOnline()
      hooks.findUserBook = goOffline
      flushFromFileBrowser()

      assert.are.equal(1, #calls.findUserBook)
      assert.are.same({}, calls.updatePage)
      assert.are.equal(50, pending(settings, FILE).progress.value)
      assert.are.equal(50, pending(settings, OTHER_FILE).progress.value)

      -- The book that was tried goes last next time.
      local tried = calls.findUserBook[1]
      goOnline()
      flushFromFileBrowser()

      assert.are.equal(3, #calls.findUserBook)
      assert.are_not.equal(tried, calls.findUserBook[2])
      assert.is_nil(pending(settings, FILE))
      assert.is_nil(pending(settings, OTHER_FILE))
    end)

    it("keeps a finished status that's rejected, after sending the progress queued with it", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)

      goOnline()
      hooks.updateUserBook = function() return true end
      flushFromFileBrowser()

      assert.are.same({ 150 }, pagesSent())
      assert.is_nil(pending(settings).progress)
      assert.is_number(pending(settings).finished_at)

      flushFromFileBrowser()

      assert.are.same({ STATUS.FINISHED, STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("sends a queued finished status even when progress can't be converted without a page count", function()
      settings:updateBookSetting(FILE, { _delete = { "pages" } })
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 100, true)

      goOnline()
      flushFromFileBrowser()

      assert.are.same({}, calls.updatePage)
      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(STATUS.FINISHED, remote.status_id)
      assert.is_nil(pending(settings) and pending(settings).finished_at)
    end)

    it("keeps queued progress after a failed write while connected, and retries it", function()
      queue(settings, FILE, 50)
      hooks.updatePage = function() return true end

      goOnline()
      flushFromFileBrowser()

      assert.are.same({ 150 }, pagesSent())
      assert.are.equal(20, remote.progress_pages)
      assert.is_table(pending(settings))
      assert.are.equal(50, pending(settings).progress.value)

      flushFromFileBrowser()

      assert.are.same({ 150, 150 }, pagesSent())
      assert.are.equal(150, remote.progress_pages)
      assert.is_nil(pending(settings))
    end)

    it("sends progress queued while an earlier one for the book was being sent", function()
      queue(settings, FILE, 30)

      goOnline()
      local browser = hardcoverEngine(newUi(nil))
      hooks.updatePage = function()
        -- The closed reader queues newer progress and tries to send it.
        queue(HardcoverSettings:new(SETTINGS_PATH, newUi(nil), nil), FILE, 60)
        engine:flushPendingUpdates()
      end
      browser:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ 90, 180 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("sends a queued update only once when flushes overlap", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)

      goOnline()
      hooks.updateUserBook = function()
        -- The file browser's flush starts while the closed reader's is still
        -- waiting for the status update.
        hardcoverEngine(newUi(nil)):flushPendingUpdates()
      end
      flushFromFileBrowser()

      assert.are.same({ STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("doesn't clear equal progress for a new book queued during the previous book's write", function()
      queue(settings, FILE, 50)
      hooks.updatePage = function()
        settings:updateBookSetting(FILE, { book_id = 44 })
        queue(settings, FILE, 50)
      end

      goOnline()
      flushFromFileBrowser()

      assert.is_table(pending(settings))
      assert.are.equal(44, pending(settings).book_id)
      assert.are.equal(50, pending(settings).progress.value)

      flushFromFileBrowser()

      assert.are.same({ 42, 44 }, calls.findUserBook)
      assert.are.same({ 150, 150 }, pagesSent())
      assert.is_nil(pending(settings))
    end)

    it("doesn't clear a new book's finished update when the previous book's write returns", function()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      hooks.updateUserBook = function()
        settings:updateBookSetting(FILE, { book_id = 44 })
        queue(settings, FILE, nil, true)
      end

      goOnline()
      flushFromFileBrowser()

      assert.is_table(pending(settings))
      assert.are.equal(44, pending(settings).book_id)
      assert.is_number(pending(settings).finished_at)

      remote.status_id = STATUS.READING
      flushFromFileBrowser()

      assert.are.same({ 42, 44 }, calls.findUserBook)
      assert.are.same({ STATUS.FINISHED, STATUS.FINISHED }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    it("doesn't cache a queued finished response for a book relinked during the write", function()
      goOnline()
      openBook()
      ui.doc_settings:saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      hooks.updateUserBook = function()
        settings:updateBookSetting(FILE, { book_id = 43 })
        engine.cache:cacheUserBook()
      end

      engine:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.equal(43, engine.state.book_status.book_id)
      assert.are.equal(STATUS.READING, engine.state.book_status.status_id)
      assert.is_nil(pending(settings))
    end)
  end)

  describe("with Goodreads", function()
    local SETTINGS_PATH = "/settings/goodreads.lua"
    local settings, calls, shelf, fails

    local function goodreadsEngine(engine_ui)
      return newEngine {
        label = "Goodreads", constants = GOODREADS_CONST, Provider = GoodreadsProvider,
        settings = GoodreadsSettings:new(SETTINGS_PATH, engine_ui, nil),
        api = {
          hasCredential = function() return true end,
          findUserBook = function(_, book_id)
            table.insert(calls.findUserBook, book_id)
            if not NetworkMgr._connected then return {}, "Failed to fetch book" end
            return { book_id = book_id, status_id = shelf }
          end,
          updateProgress = function(_, _book_id, value)
            table.insert(calls.updateProgress, value)
            return { status_id = GOODREADS_CONST.STATUS.READING }
          end,
          updateUserBook = function(_, _book_id, status_id)
            table.insert(calls.updateUserBook, status_id)
            -- e.g. answered by Goodreads' bot check, which it takes for success
            if fails.status then return { status_id = shelf } end
            shelf = status_id
            -- Like the real one, nil if the response is lost, even if the shelf was set.
            if not fails.response then return { status_id = status_id } end
          end,
          setDateFinished = function(_, book_id, finished_at)
            table.insert(calls.setDateFinished, { book_id, finished_at })
            -- e.g. Wi-Fi lost during the request
            if fails.connection then goOffline() end
            return not (fails.date or fails.connection)
          end,
        },
        ui = engine_ui,
      }
    end

    local function flushFromFileBrowser()
      goodreadsEngine(newUi(nil)):flushPendingUpdates()
      UIManager:_runUntilIdle()
    end

    -- Counts the "book finished" broadcasts, for main.lua's "submit a review?" prompt.
    local function countAnnounced()
      local count, listening = 0, true
      UIManager._addListener(function(event)
        if listening and event.name == "ShelfSyncBookFinished" then count = count + 1 end
      end)
      finally(function() listening = false end)
      return function() return count end
    end

    before_each(function()
      ReaderUI.instance = nil
      settings = GoodreadsSettings:new(SETTINGS_PATH, newUi(nil), nil)
      settings:updateBookSetting(FILE, { book_id = "42", pages = 300 })
      DocSettings:open(FILE):saveSetting("summary", { status = "complete" })
      calls = { findUserBook = {}, updateProgress = {}, updateUserBook = {}, setDateFinished = {} }
      shelf = GOODREADS_CONST.STATUS.READING
      fails = {}
      goOnline()
    end)

    it("sends queued progress for up to a day, as there's no remote progress to check it against", function()
      queue(settings, FILE, 40)
      age(settings, FILE, DAY - 60)
      flushFromFileBrowser()

      assert.are.same({ 40 }, calls.updateProgress)
      assert.is_nil(pending(settings))
    end)

    it("drops queued progress older than a day, but still sends a queued finished status, dated when it was finished", function()
      queue(settings, FILE, 40, true)
      age(settings, FILE, DAY + 60)
      local finished_at = pending(settings).finished_at
      flushFromFileBrowser()

      assert.are.same({}, calls.updateProgress)
      assert.are.same({ GOODREADS_CONST.STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({ { "42", finished_at } }, calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("sends a queued finished status instead of the progress queued with it, so it's dated when it was finished", function()
      queue(settings, FILE, 100, true)
      age(settings, FILE, 12 * 3600)
      local finished_at = pending(settings).finished_at
      flushFromFileBrowser()

      assert.are.same({}, calls.updateProgress)
      assert.are.same({ GOODREADS_CONST.STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({ { "42", finished_at } }, calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("keeps a queued finished status until it's dated, even once the book's on the read shelf", function()
      queue(settings, FILE, nil, true)
      local finished_at = pending(settings).finished_at

      -- The shelf is set, but the response is lost.
      fails.response = true
      flushFromFileBrowser()
      assert.are.same({}, calls.setDateFinished)
      assert.are.equal(finished_at, pending(settings).finished_at)

      -- Already read, so only the date is set, but that fails.
      fails = { date = true }
      flushFromFileBrowser()
      assert.are.equal(finished_at, pending(settings).finished_at)

      -- Not tried again for an hour.
      fails = {}
      flushFromFileBrowser()
      assert.are.equal(1, #calls.setDateFinished)

      waitForDateRetry(settings)
      flushFromFileBrowser()

      assert.are.same({ GOODREADS_CONST.STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({ { "42", finished_at }, { "42", finished_at } }, calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("queues a finish date when the Goodreads shelf saves but the date request fails", function()
      goOnline()
      fails.date = true
      local engine = goodreadsEngine(newUi(nil))

      engine:onDocSettingsItemsChanged(FILE, { summary = { status = "complete" } })
      UIManager:_runUntilIdle()

      local queued = pending(settings)
      assert.are.same({ GOODREADS_CONST.STATUS.FINISHED }, calls.updateUserBook)
      assert.are.equal(1, #calls.setDateFinished)
      assert.is_number(queued.finished_at)
      assert.are.equal(calls.setDateFinished[1][2], queued.finished_at)

      -- A later sync sees the shelf is already Finished and retries only the
      -- date, then clears the queue after confirmation.
      fails = {}
      flushFromFileBrowser()

      assert.are.equal(1, #calls.updateUserBook)
      assert.are.same({ { "42", queued.finished_at }, { "42", queued.finished_at } }, calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("gives up on the date after 3 tries an hour apart, without looking the book up in between", function()
      queue(settings, FILE, nil, true)
      local finished_at = pending(settings).finished_at
      fails.date = true

      flushFromFileBrowser()
      flushFromFileBrowser()
      assert.are.equal(1, #calls.findUserBook)
      assert.are.equal(1, #calls.setDateFinished)

      waitForDateRetry(settings, FILE, 59 * 60)
      flushFromFileBrowser()
      assert.are.equal(1, #calls.setDateFinished)

      waitForDateRetry(settings, FILE, 60)
      flushFromFileBrowser()
      assert.are.equal(finished_at, pending(settings).finished_at)

      waitForDateRetry(settings)
      flushFromFileBrowser()

      assert.are.same({ GOODREADS_CONST.STATUS.FINISHED }, calls.updateUserBook)
      assert.are.same({ { "42", finished_at }, { "42", finished_at }, { "42", finished_at } }, calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("doesn't count a try at the date that failed as the network was lost", function()
      queue(settings, FILE, nil, true)
      fails.connection = true
      flushFromFileBrowser()
      assert.is_truthy(pending(settings).finished_at)

      goOnline()
      fails = { date = true }
      flushFromFileBrowser()
      waitForDateRetry(settings)
      flushFromFileBrowser()
      assert.are.equal(3, #calls.setDateFinished)
      assert.is_truthy(pending(settings).finished_at)

      waitForDateRetry(settings)
      flushFromFileBrowser()
      assert.are.equal(4, #calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("tries the date again if the clock's been put back since the last try", function()
      queue(settings, FILE, nil, true)
      fails.date = true
      flushFromFileBrowser()
      waitForDateRetry(settings, FILE, -2 * 3600)
      flushFromFileBrowser()

      assert.are.equal(2, #calls.setDateFinished)
    end)

    it("doesn't try the date again early when progress is queued with it, and drops the progress", function()
      local announced = countAnnounced()
      queue(settings, FILE, nil, true)
      fails.date = true
      flushFromFileBrowser()
      queue(settings, FILE, 100)
      flushFromFileBrowser()

      assert.are.equal(1, #calls.setDateFinished)
      assert.is_truthy(pending(settings).finished_at)
      assert.is_nil(pending(settings).progress)
      -- Nothing was sent, so it's not announced again.
      assert.are.equal(1, announced())

      -- So the book's not looked up again until the date's due.
      flushFromFileBrowser()
      assert.are.equal(2, #calls.findUserBook)
    end)

    it("doesn't try the date again early when the status has to be sent again, but still announces it", function()
      local announced = countAnnounced()
      queue(settings, FILE, nil, true)
      fails.date = true
      flushFromFileBrowser()

      -- e.g. moved back to Currently Reading there
      shelf = GOODREADS_CONST.STATUS.READING
      queue(settings, FILE, 100)
      flushFromFileBrowser()

      local FINISHED = GOODREADS_CONST.STATUS.FINISHED
      assert.are.same({ FINISHED, FINISHED }, calls.updateUserBook)
      assert.are.equal(1, #calls.setDateFinished)
      assert.is_truthy(pending(settings).finished_at)
      -- As when it was first sent.
      assert.are.equal(2, announced())
    end)

    it("keeps a queued finished status that didn't go through, however often the date fails", function()
      queue(settings, FILE, nil, true)
      -- e.g. both answered by Goodreads' bot check
      fails = { status = true, date = true }
      for _ = 1, 4 do flushFromFileBrowser() end

      assert.are.equal(4, #calls.updateUserBook)
      assert.are.equal(4, #calls.setDateFinished)
      assert.is_truthy(pending(settings).finished_at)

      fails = {}
      flushFromFileBrowser()
      assert.are.equal(GOODREADS_CONST.STATUS.FINISHED, shelf)
      assert.is_nil(pending(settings))
    end)

    it("tries the date of a book finished again right away, with all its tries", function()
      queue(settings, FILE, nil, true)
      fails.date = true
      flushFromFileBrowser()
      waitForDateRetry(settings)
      flushFromFileBrowser()
      assert.are.equal(2, #calls.setDateFinished)

      -- Marked as reading again and read on offline, so its progress stays
      -- queued, then finished again.
      goOffline()
      queue(settings, FILE, 40)
      DocSettings:open(FILE):saveSetting("summary", { status = "reading" })
      goodreadsEngine(newUi(nil)):onDocSettingsItemsChanged(FILE, { summary = { status = "reading" } })
      UIManager:_runUntilIdle()
      assert.is_nil(pending(settings).finished_at)
      -- Still read there, as that was offline.
      shelf = GOODREADS_CONST.STATUS.FINISHED
      DocSettings:open(FILE):saveSetting("summary", { status = "complete" })
      queue(settings, FILE, nil, true)
      goOnline()
      flushFromFileBrowser()

      assert.are.equal(3, #calls.setDateFinished)
      assert.is_truthy(pending(settings).finished_at)
    end)

    it("dates a queued finished status when the book's marked finished again, and keeps it until it's dated", function()
      queue(settings, FILE, nil, true)
      age(settings, FILE, DAY)
      local finished_at = pending(settings).finished_at

      -- The shelf is set, but the date isn't.
      fails.date = true
      flushFromFileBrowser()
      assert.are.equal(finished_at, pending(settings).finished_at)

      -- e.g. turning past the last page again
      local ui = newUi(document)
      ReaderUI.instance = ui
      local engine = goodreadsEngine(ui)
      engine:onEndOfBook()
      UIManager:_runUntilIdle()
      assert.are.equal(finished_at, pending(settings).finished_at)

      fails = {}
      engine:onEndOfBook()
      UIManager:_runUntilIdle()

      local FINISHED = GOODREADS_CONST.STATUS.FINISHED
      assert.are.same({ FINISHED, FINISHED, FINISHED }, calls.updateUserBook)
      assert.are.same({ { "42", finished_at }, { "42", finished_at }, { "42", finished_at } },
        calls.setDateFinished)
      assert.is_nil(pending(settings))
    end)

    it("keeps queued progress while the book's shelf can't be read, and sends it once it can", function()
      DocSettings:open(FILE):saveSetting("summary", { status = "reading" })
      queue(settings, FILE, 40)

      -- e.g. a page that loaded without the user's shelf on it
      shelf = nil
      flushFromFileBrowser()

      assert.are.same({}, calls.updateProgress)
      assert.are.equal(40, pending(settings).progress.value)

      shelf = GOODREADS_CONST.STATUS.READING
      flushFromFileBrowser()

      assert.are.same({ 40 }, calls.updateProgress)
      assert.is_nil(pending(settings))
    end)
  end)

  describe("with Pagebound", function()
    local SETTINGS_PATH = "/settings/pagebound.lua"

    it("keeps the book UUID for a manual status delayed until after the book closes", function()
      local ui = newUi(document)
      ReaderUI.instance = ui
      local settings = PageboundSettings:new(SETTINGS_PATH, ui, nil)
      settings:updateBookSetting(FILE, { book_id = "42", book_uuid = "uuid-42", pages = 300 })
      settings:updateBookSetting(OTHER_FILE, { book_id = "43", book_uuid = "uuid-43", pages = 300 })

      local json = require("json")
      json.util = json.util or { null = {} }
      json.util.InitArray = json.util.InitArray or function(values) return values end
      local reader, saved
      local status_id = PAGEBOUND_CONST.STATUS.READING
      local requests = {}
      local api = setmetatable({
        settings = settings,
        hasCredential = function() return true end,
        findUserBook = function(_, book_id, _user_id, book_uuid)
          if not book_uuid then return {}, "Missing Pagebound book UUID" end
          return {
            id = "user-" .. book_id, book_id = book_id, book_uuid = book_uuid,
            status_id = book_id == "42" and status_id or PAGEBOUND_CONST.STATUS.READING,
            total_page_count = 300, user_book_reads = { { id = 9 } },
          }
        end,
        updateProgress = function()
          reader.cache:queueBookStatus(FILE, PAGEBOUND_CONST.STATUS.READING, function(result) saved = result end)
          reader:onDocumentClose()
          ui.document = nil
          ReaderUI.instance = nil
          return { status_id = PAGEBOUND_CONST.STATUS.READING, total_page_count = 300 }
        end,
        request = function(_, path, method, payload)
          table.insert(requests, { path = path, method = method, status = payload.status })
          status_id = PAGEBOUND_CONST.STATUS_BY_SYSTEM_STATUS[payload.status]
          return 200, {}
        end,
      }, { __index = PageboundApi })
      reader = newEngine {
        label = "Pagebound", constants = PAGEBOUND_CONST, Provider = PageboundProvider,
        settings = settings, api = api, ui = ui,
      }

      goOnline()
      reader.cache:queueBookStatus(FILE, PAGEBOUND_CONST.STATUS.FINISHED, function(result) saved = result end)
      assert.is_true(saved)
      saved = nil
      queue(settings, OTHER_FILE, 50)
      reader:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.is_true(saved)
      assert.are.same({
        { path = "/api/v1/user_books/user-42", method = "PUT", status = "finished" },
        { path = "/api/v1/user_books/user-42", method = "PUT", status = "current" },
      }, requests)
      assert.is_nil(pending(settings, OTHER_FILE))
    end)

    for _, has_read in ipairs({ true, false }) do
      it("uses a closed book's page count when the remote count is missing and the session "
        .. (has_read and "exists" or "must be created"), function()
        ReaderUI.instance = nil
        local settings = PageboundSettings:new(SETTINGS_PATH, newUi(nil), nil)
        settings:updateBookSetting(FILE, { book_id = "42", book_uuid = "uuid-42", pages = 300 })
        settings.pending_updates:addProgress(FILE, settings:readBookSettings(FILE), 150, "pages")

        local json = require("json")
        json.util = json.util or { null = {} }
        local requests = {}
        local read = has_read and { id = 9, user_book_id = 99 } or nil
        local api = setmetatable({
          settings = settings,
          hasCredential = function() return true end,
          findUserBook = function(_, book_id, _user_id, book_uuid)
            return {
              id = "user-book", book_id = book_id, book_uuid = book_uuid,
              status_id = PAGEBOUND_CONST.STATUS.READING, current_page = 30,
              current_reading_instance = read, user_book_reads = read and { read },
            }
          end,
          updateUserBook = function(self, book_id, _status_id, _page_count, book_uuid)
            read = { id = 9, user_book_id = 99 }
            return self:findUserBook(book_id, nil, book_uuid)
          end,
          request = function(_, path, method, payload)
            table.insert(requests, {
              path = path, method = method,
              total_progress = payload.reading_update.total_progress,
              total_page_count = payload.user_book.total_page_count,
              current_page = payload.user_book.current_page,
            })
            return 201, {}
          end,
        }, { __index = PageboundApi })

        goOnline()
        newEngine {
          label = "Pagebound", constants = PAGEBOUND_CONST, Provider = PageboundProvider,
          settings = settings, api = api, ui = newUi(nil),
        }:flushPendingUpdates()
        UIManager:_runUntilIdle()

        assert.are.same({ {
          path = "/api/v1/reading_updates", method = "POST",
          total_progress = 50, total_page_count = 300, current_page = "150",
        } }, requests)
        assert.is_nil(pending(settings))
      end)
    end

    it("sends queued updates for a closed book using its UUID", function()
      ReaderUI.instance = nil
      local settings = PageboundSettings:new(SETTINGS_PATH, newUi(nil), nil)
      settings:updateBookSetting(FILE, { book_id = "42", book_uuid = "uuid-42", pages = 300 })
      DocSettings:open(FILE):saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)

      local calls = { updateProgress = {}, updateUserBook = {} }
      local READING = PAGEBOUND_CONST.STATUS.READING
      local api = {
        hasCredential = function() return true end,
        findUserBook = function(_, book_id, _user_id, book_uuid)
          if book_uuid ~= "uuid-42" then return {}, "Missing Pagebound book UUID" end
          return {
            id = "user-book", book_id = book_id, book_uuid = book_uuid, status_id = READING,
            progress_method = "pages", current_page = 30, total_page_count = 300,
            current_reading_instance = { id = 9 }, user_book_reads = { { id = 9 } },
          }
        end,
        updateProgress = function(_, _book_id, status, current_read, value, update_type, current_page)
          table.insert(calls.updateProgress, {
            uuid = status.book_uuid, read_id = current_read.id, value = value,
            update_type = update_type, current_page = current_page,
          })
          return { status_id = READING, total_page_count = 300 }
        end,
        updateUserBook = function(_, _book_id, status_id, _page_count, book_uuid)
          table.insert(calls.updateUserBook, { status_id = status_id, uuid = book_uuid })
          return { status_id = status_id }
        end,
      }

      goOnline()
      newEngine {
        label = "Pagebound", constants = PAGEBOUND_CONST, Provider = PageboundProvider,
        settings = PageboundSettings:new(SETTINGS_PATH, newUi(nil), nil), api = api, ui = newUi(nil),
      }:flushPendingUpdates()
      UIManager:_runUntilIdle()

      -- No current page: that's only known for the open book.
      assert.are.same({ { uuid = "uuid-42", read_id = 9, value = 50, update_type = "percentage" } },
        calls.updateProgress)
      assert.are.same({ { status_id = PAGEBOUND_CONST.STATUS.FINISHED, uuid = "uuid-42" } }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)

    for _, page_count in ipairs({ "the book's", "no" }) do
      it("drops queued progress that's behind the remote when Pagebound has no page count, using "
        .. page_count .. " page count", function()
        ReaderUI.instance = nil
        local settings = PageboundSettings:new(SETTINGS_PATH, newUi(nil), nil)
        settings:updateBookSetting(FILE,
          { book_id = "42", book_uuid = "uuid-42", pages = page_count ~= "no" and 300 or nil })
        queue(settings, FILE, 50)

        local updates = {}
        local api = {
          hasCredential = function() return true end,
          findUserBook = function(_, book_id, _user_id, book_uuid)
            -- Page 240 of 300, which Pagebound also keeps as 80%.
            return {
              id = "user-book", book_id = book_id, book_uuid = book_uuid,
              status_id = PAGEBOUND_CONST.STATUS.READING, progress_method = "pages",
              current_page = 240, progress = 80,
              current_reading_instance = { id = 9 }, user_book_reads = { { id = 9 } },
            }
          end,
          updateProgress = function(_, _book_id, _status, _current_read, value)
            table.insert(updates, value)
            return { status_id = PAGEBOUND_CONST.STATUS.READING }
          end,
        }

        goOnline()
        newEngine {
          label = "Pagebound", constants = PAGEBOUND_CONST, Provider = PageboundProvider,
          settings = settings, api = api, ui = newUi(nil),
        }:flushPendingUpdates()
        UIManager:_runUntilIdle()

        assert.are.same({}, updates)
        assert.is_nil(pending(settings))
      end)
    end

    it("sends a queued finished status for a deleted book using the UUID kept with it", function()
      ReaderUI.instance = nil
      local settings = PageboundSettings:new(SETTINGS_PATH, newUi(nil), nil)
      settings:updateBookSetting(FILE, { book_id = "42", book_uuid = "uuid-42", pages = 300 })
      DocSettings:open(FILE):saveSetting("summary", { status = "complete" })
      queue(settings, FILE, 50, true)
      mocks.deleteBook(FILE)

      local calls = { findUserBook = {}, updateUserBook = {} }
      local api = {
        hasCredential = function() return true end,
        findUserBook = function(_, book_id, _user_id, book_uuid)
          table.insert(calls.findUserBook, book_uuid)
          if book_uuid ~= "uuid-42" then return {}, "Missing Pagebound book UUID" end
          return {
            id = "user-book", book_id = book_id, book_uuid = book_uuid,
            status_id = PAGEBOUND_CONST.STATUS.READING, user_book_reads = { { id = 9 } },
          }
        end,
        updateUserBook = function(_, _book_id, status_id, _page_count, book_uuid)
          table.insert(calls.updateUserBook, { status_id = status_id, uuid = book_uuid })
          return { status_id = status_id }
        end,
      }

      goOnline()
      newEngine {
        label = "Pagebound", constants = PAGEBOUND_CONST, Provider = PageboundProvider,
        settings = PageboundSettings:new(SETTINGS_PATH, newUi(nil), nil), api = api, ui = newUi(nil),
      }:flushPendingUpdates()
      UIManager:_runUntilIdle()

      assert.are.same({ "uuid-42" }, calls.findUserBook)
      assert.are.same({ { status_id = PAGEBOUND_CONST.STATUS.FINISHED, uuid = "uuid-42" } }, calls.updateUserBook)
      assert.is_nil(pending(settings))
    end)
  end)
end)
