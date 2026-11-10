-- Regression tests for cancelling the book lookup that startReadCache retries
-- (#31). A suspend, a Wi-Fi drop, turning the provider off and opening a
-- Wikipedia document each stop the lookup, including a try that's already
-- waiting for Wi-Fi or a request. Every provider's engine shares Scheduler,
-- so each one cancels only its own lookup.

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr = mocks.UIManager, mocks.NetworkMgr

local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local Scheduler = require("shelfsync/lib/common/scheduler")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local GoodreadsProvider = require("shelfsync/lib/goodreads/provider")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local HardcoverProvider = require("shelfsync/lib/hardcover/provider")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")

local FILE = "/books/test.epub"

describe("Scheduler:withRetries cancel", function()
  before_each(function()
    mocks.reset()
  end)

  it("unschedules the next try", function()
    local tries = 0
    local cancel = Scheduler:withRetries(6, 3, function(_success, fail)
      tries = tries + 1
      fail()
    end)
    UIManager:_runUntil(0)
    assert.are.equal(1, tries)

    cancel()
    UIManager:_runUntilIdle()
    assert.are.equal(1, tries)
  end)

  it("doesn't let a try that's already running retry or call back", function()
    for _, limit in ipairs({ 1, 6 }) do
      local try, tries, calls = nil, 0, {}
      local cancel = Scheduler:withRetries(limit, 3, function(success, fail, is_cancelled)
        tries = tries + 1
        try = { success = success, fail = fail, is_cancelled = is_cancelled }
      end, function()
        table.insert(calls, "success")
      end, function()
        table.insert(calls, "fail")
      end)
      UIManager:_runUntil(0)
      assert.is_false(try.is_cancelled())

      cancel()
      assert.is_true(try.is_cancelled())
      try.fail()
      try.success()
      UIManager:_runUntilIdle()
      assert.are.equal(1, tries)
      assert.are.same({}, calls)
    end
  end)
end)

describe("Cancelling startReadCache's book lookup", function()
  local ui, props

  before_each(function()
    mocks.reset()
    NetworkMgr._wifi_on = true
    NetworkMgr._connected = true
    props = { title = "Test Book", authors = "Test Author" }
    ui = {
      document = {
        file = FILE,
        getProps = function() return props end,
      },
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      getCurrentPage = function() return 1 end,
      doc_settings = mocks.makeStore(),
    }
  end)

  after_each(function()
    -- Leaves no Wi-Fi session or queued update behind for the next test.
    UIManager:_runUntilIdle()
  end)

  -- `api.respond` answers each lookup. By default the book page can't be
  -- fetched, so the lookup keeps retrying.
  local function buildEngine(label, settings_class, provider_class, constants)
    local settings = settings_class:new("/settings/" .. label .. ".lua", ui, nil)
    settings:updateBookSetting(FILE, { book_id = "1" })

    local api = {
      requests = 0,
      writes = {},
      respond = function() return {}, "HTTP 503" end,
      hasCredential = function() return true end,
      findUserBook = function(self)
        self.requests = self.requests + 1
        return self.respond(self.requests)
      end,
      updateUserBook = function(self, book_id, status_id)
        table.insert(self.writes, status_id)
        return { id = book_id, book_id = book_id, status_id = status_id }
      end,
    }
    local state = { book_status = {} }
    local user = { getId = function() return 1 end }
    local wifi = AutoWifi:new { settings = settings, label = label }
    local cache = Cache:new { api = api, user = user, settings = settings, state = state, ui = ui, wifi = wifi }
    local provider = provider_class:new {
      label = label,
      api = api, user = user, cache = cache, dialog_manager = {},
      settings = settings, state = state, ui = ui, wifi = wifi,
    }
    cache.provider = provider

    local engine = SyncEngine:new {
      label = label,
      constants = constants,
      highlight_menu_name = "hl_" .. label,
      api = api, user = user, cache = cache,
      page_mapper = { cachePageMap = function() end },
      wifi = wifi, dialog_manager = {},
      provider = provider, settings = settings,
      plugin_settings = settings,
      ui = ui, state = state,
    }
    return engine, api
  end

  local function goodreadsEngine()
    return buildEngine("Goodreads", GoodreadsSettings, GoodreadsProvider, GOODREADS)
  end

  local function turnOff(engine)
    engine.settings:setProviderEnabled(false)
    engine:onSettingsChanged(SETTING.PROVIDER_ENABLED, false)
  end

  for _, case in ipairs({
    { "a suspend", function(engine) engine:onSuspend() end },
    { "a Wi-Fi drop", function(engine) engine:onNetworkDisconnecting() end },
    { "turning the provider off", turnOff },
    { "opening a Wikipedia document", function(engine)
      props = { title = "Lua", authors = "Wikipedia en" }
      engine:onReaderReady()
    end },
  }) do
    it("stops retrying after " .. case[1], function()
      local engine, api = goodreadsEngine()
      engine:startReadCache()
      UIManager:_runUntil(0)
      assert.are.equal(1, api.requests)

      case[2](engine)
      UIManager:_runUntilIdle()
      assert.are.equal(1, api.requests)
    end)
  end

  it("keeps a single lookup going while a failing book is suspended and woken", function()
    local engine, api = goodreadsEngine()
    engine:startReadCache()
    UIManager:_runUntil(0)

    for _ = 1, 3 do
      engine:onSuspend()
      engine:onResume()
      -- onResume starts the lookup again 2 s later.
      UIManager:_runUntil(mocks.Clock.now + 2)
    end
    UIManager:_runUntilIdle()

    -- One try each for the first three lookups, then all six of the last
    -- one. Without cancelling, each of the four kept all six tries (24).
    assert.are.equal(3 + 6, api.requests)
  end)

  it("makes no request for a lookup that was waiting for Wi-Fi when the provider was turned off", function()
    NetworkMgr._wifi_on = false
    NetworkMgr._connected = false
    local engine, api = goodreadsEngine()
    engine.settings:updateSetting(SETTING.SHARED.ENABLE_WIFI, true)

    engine:startReadCache()
    UIManager:_runUntil(0.5)
    assert.are.equal(0, api.requests)

    turnOff(engine)
    UIManager:_runUntilIdle()
    assert.are.equal(0, api.requests)
  end)

  it("doesn't add the book to Currently Reading if it's turned off during the lookup", function()
    local engine, api = goodreadsEngine()
    -- The book is on no shelf, so it's added to Currently Reading once the
    -- third lookup confirms that. The provider is turned off while that
    -- lookup's request is still running.
    api.respond = function(requests)
      if requests == 3 then
        UIManager:scheduleIn(1, function() turnOff(engine) end)
      end
      coroutine.yield(5)
      return { id = "1", book_id = "1", shelved = false }
    end

    engine:startReadCache()
    UIManager:_runUntilIdle()

    assert.are.equal(3, api.requests)
    assert.are.same({}, api.writes)
  end)

  it("adds the book to Currently Reading when the lookup isn't cancelled", function()
    local engine, api = goodreadsEngine()
    api.respond = function()
      coroutine.yield(5)
      return { id = "1", book_id = "1", shelved = false }
    end

    engine:startReadCache()
    UIManager:_runUntilIdle()

    assert.are.equal(3, api.requests)
    assert.are.same({ GOODREADS.STATUS.READING }, api.writes)
    assert.is_true(engine.state.process_page_turns)
  end)

  it("doesn't start a new lookup when a book is linked automatically after a suspend", function()
    local other_file = "/books/other.epub"
    ui.document.file = other_file
    local engine, api = goodreadsEngine()
    -- Linking can wait for Wi-Fi, so it can finish after the lookup that
    -- started it has been cancelled.
    engine.provider.tryAutolink = function(_, done)
      UIManager:scheduleIn(5, function()
        engine.settings:updateBookSetting(other_file, { book_id = "1" })
        done()
      end)
    end

    engine:startReadCache()
    UIManager:_runUntil(0)
    engine:onSuspend()
    UIManager:_runUntilIdle()

    assert.are.equal(0, api.requests)
  end)

  it("still looks up a book with tracking off after a suspend just after it opens", function()
    local engine, api = goodreadsEngine()
    -- onResume only starts the lookup again when progress is tracked, so a
    -- book that isn't relies on the start that onReaderReady scheduled.
    engine.settings:updateBookSetting(FILE, { sync = false })
    engine:onReaderReady()
    UIManager:_runUntil(0.5)
    engine:onSuspend()
    engine:onResume()
    UIManager:_runUntilIdle()

    assert.are.equal(6, api.requests)
  end)

  it("keeps another provider's lookup going when one provider is turned off", function()
    local goodreads, goodreads_api = goodreadsEngine()
    local hardcover, hardcover_api = buildEngine("Hardcover", HardcoverSettings, HardcoverProvider, HARDCOVER)
    goodreads:startReadCache()
    hardcover:startReadCache()
    UIManager:_runUntil(0)

    turnOff(goodreads)
    UIManager:_runUntilIdle()

    assert.are.equal(1, goodreads_api.requests)
    assert.are.equal(6, hardcover_api.requests)
  end)
end)
