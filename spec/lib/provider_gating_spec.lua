-- Covers the two gates SyncEngine:isActive() enforces before any
-- provider-specific action (autolink, page-progress pushes, dispatcher
-- actions like link/track) is allowed to run:
--   1. The per-provider "Enabled" toggle (SETTING.PROVIDER_ENABLED).
--   2. Having a usable credential configured (HardcoverApi:hasCredential()).
-- Both must independently result in a no-op: no API calls, no state changes.

local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager

local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local HardcoverProvider = require("shelfsync/lib/hardcover/provider")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local HardcoverApi = require("shelfsync/lib/hardcover/api")
local HARDCOVER_CONST = require("shelfsync/lib/hardcover/constants")

describe("Provider enable/credential gating", function()
  local ui, doc_settings, settings, calls, api, provider_instance, engine, state

  before_each(function()
    mocks.reset()

    doc_settings = mocks.makeStore()
    ui = {
      document = {
        file = "/books/test.epub",
        getProps = function()
          return { title = "Test Book", authors = "Test Author", identifiers = "isbn:1234567890123" }
        end,
        getPageCount = function() return 300 end,
      },
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      getCurrentPage = function() return 1 end,
      doc_settings = doc_settings,
    }

    settings = HardcoverSettings:new("/settings/hardcover.lua", ui, nil)
    settings:updateSetting(SETTING.SHARED.LINK_BY_ISBN, true)
    settings:updateSetting(SETTING.SHARED.LINK_BY_TITLE, true)
    settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)

    calls = {
      findBookByIdentifiers = 0,
      findBooks = 0,
      findUserBook = 0,
      updateUserBook = 0,
      updatePage = 0,
      createRead = 0,
      cacheUserBook = 0,
    }

    -- Real HardcoverApi as the metatable fallback (not overridden below) so
    -- hasCredential() exercises the actual setting/legacy-config resolution
    -- logic, while the network-touching methods are spies.
    api = setmetatable({
      settings = settings,
      findBookByIdentifiers = function() calls.findBookByIdentifiers = calls.findBookByIdentifiers + 1; return nil end,
      findBooks = function() calls.findBooks = calls.findBooks + 1; return {} end,
      findUserBook = function() calls.findUserBook = calls.findUserBook + 1; return nil end,
      updateUserBook = function() calls.updateUserBook = calls.updateUserBook + 1; return {} end,
      updatePage = function() calls.updatePage = calls.updatePage + 1; return {} end,
      createRead = function() calls.createRead = calls.createRead + 1; return {} end,
    }, { __index = HardcoverApi })

    state = { page = nil, pos = nil, search_results = {}, book_status = {} }
    local wifi = AutoWifi:new { settings = settings, label = "Hardcover" }
    local user = { getId = function() return 1 end }
    local cache = {
      cacheUserBook = function()
        calls.cacheUserBook = calls.cacheUserBook + 1
      end,
    }
    local dialog_manager = {}

    provider_instance = HardcoverProvider:new {
      label = "Hardcover",
      api = api, user = user, cache = cache, dialog_manager = dialog_manager,
      settings = settings, state = state, ui = ui, wifi = wifi,
    }

    engine = SyncEngine:new {
      label = "Hardcover",
      constants = HARDCOVER_CONST,
      highlight_menu_name = "hl_hardcover",
      auth_setting_key = "hardcover_auth",
      api = api, user = user, cache = cache,
      page_mapper = {
        cachePageMap = function() end,
        getRemotePagePercent = function() return 0, nil end,
      },
      wifi = wifi, dialog_manager = dialog_manager,
      provider = provider_instance, settings = settings,
      plugin_settings = settings,
      ui = ui, view = {}, state = state,
    }

    -- Mirrors main.lua's _buildEngine wiring, so settings:setProviderEnabled()
    -- below drives the real onSettingsChanged(PROVIDER_ENABLED, ...) path.
    settings:subscribe(function(field, change, original_value)
      engine:onSettingsChanged(field, change, original_value)
    end)
  end)

  local function assertNoCallsMade()
    assert.are.equal(0, calls.findBookByIdentifiers)
    assert.are.equal(0, calls.findBooks)
    assert.are.equal(0, calls.findUserBook)
    assert.are.equal(0, calls.updateUserBook)
    assert.are.equal(0, calls.updatePage)
    assert.are.equal(0, calls.createRead)
    assert.are.equal(0, calls.cacheUserBook)
  end

  describe("baseline (enabled and credentialed)", function()
    it("is active and actually attempts an autolink lookup", function()
      settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, "a-real-token")

      assert.is_true(engine:isActive())

      provider_instance:tryAutolink()
      UIManager:_runUntilIdle()

      assert.is_true(calls.findBookByIdentifiers > 0)
    end)

    it("refreshes an unknown remote status before a gesture update", function()
      settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, "a-real-token")
      settings:updateBookSetting(ui.document.file, { book_id = 42, edition_id = 7, pages = 300 })
      engine.cache.cacheUserBook = function()
        calls.cacheUserBook = calls.cacheUserBook + 1
        state.book_status = {
          id = 42,
          status_id = HARDCOVER_CONST.STATUS.READING,
          user_book_reads = {},
        }
      end

      local completed = false
      engine:onUpdateProgress(function(result)
        completed = result ~= nil
      end, true)
      UIManager:_runUntilIdle()

      assert.are.equal(1, calls.cacheUserBook)
      assert.are.equal(1, calls.createRead)
      assert.is_true(completed)
    end)
  end)

  describe("when the provider is disabled", function()
    before_each(function()
      settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, "a-real-token")
      settings:setProviderEnabled(false)
    end)

    it("is not active despite having a credential", function()
      assert.is_true(api:hasCredential())
      assert.is_false(engine:isActive())
    end)

    it("does not autolink or arm periodic sync on reader ready", function()
      engine:onReaderReady()
      UIManager:_runUntilIdle()

      assertNoCallsMade()
      assert.is_falsy(engine.state.process_page_turns)
    end)

    it("ignores dispatcher actions", function()
      local sync_before = engine.settings:syncEnabled()

      engine:onLink()
      engine:onTrack()
      engine:onStopTrack()
      engine:onPullPosition()
      UIManager:_runUntilIdle()

      assertNoCallsMade()
      assert.are.equal(sync_before, engine.settings:syncEnabled())
    end)

    it("does not push progress for an already-linked book", function()
      settings:updateBookSetting(ui.document.file, { book_id = 42, edition_id = 7, pages = 300 })
      engine.state.book_status = { id = 42, status_id = HARDCOVER_CONST.STATUS.READING }

      engine:onUpdateProgress()
      UIManager:_runUntilIdle()

      assert.are.equal(0, calls.updatePage)
      assert.are.equal(0, calls.createRead)
    end)
  end)

  describe("when no API token is configured", function()
    it("is not active even though the provider itself is enabled", function()
      assert.is_true(settings:providerEnabled())
      assert.is_false(api:hasCredential())
      assert.is_false(engine:isActive())
    end)

    it("does not autolink or arm periodic sync on reader ready", function()
      engine:onReaderReady()
      UIManager:_runUntilIdle()

      assertNoCallsMade()
      assert.is_falsy(engine.state.process_page_turns)
    end)

    it("ignores dispatcher actions", function()
      local sync_before = engine.settings:syncEnabled()

      engine:onLink()
      engine:onTrack()
      engine:onStopTrack()
      engine:onPullPosition()
      UIManager:_runUntilIdle()

      assertNoCallsMade()
      assert.are.equal(sync_before, engine.settings:syncEnabled())
    end)

    it("does not push progress for an already-linked book", function()
      settings:updateBookSetting(ui.document.file, { book_id = 42, edition_id = 7, pages = 300 })
      engine.state.book_status = { id = 42, status_id = HARDCOVER_CONST.STATUS.READING }

      engine:onUpdateProgress()
      UIManager:_runUntilIdle()

      assert.are.equal(0, calls.updatePage)
      assert.are.equal(0, calls.createRead)
    end)

    it("becomes active again once a token is set", function()
      settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, "a-real-token")

      assert.is_true(api:hasCredential())
      assert.is_true(engine:isActive())
    end)
  end)

  describe("re-enabling after having been disabled", function()
    it("resumes periodic tracking instead of getting stuck as \"already started\"", function()
      settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, "a-real-token")
      settings:updateBookSetting(ui.document.file, { book_id = 42, edition_id = 7, pages = 300 })
      engine.state.book_status = { id = 42, status_id = HARDCOVER_CONST.STATUS.READING }

      -- Simulate a book that was already linked and actively tracking
      -- (i.e. startReadCache already ran to completion) before disabling.
      engine.state.read_cache_started = true
      engine.state.process_page_turns = true

      settings:setProviderEnabled(false)
      assert.is_false(engine.state.process_page_turns)
      assert.is_false(engine.state.read_cache_started)

      settings:setProviderEnabled(true)
      UIManager:_runUntilIdle()

      assert.is_true(engine.state.process_page_turns)
    end)
  end)
end)
