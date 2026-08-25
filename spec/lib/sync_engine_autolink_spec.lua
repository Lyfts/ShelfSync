-- Regression test for a race between the StoryGraph and Hardcover engines'
-- startReadCache -> tryAutolink chains when a book is opened while wifi is
-- off (a common case on e-readers that power wifi down on sleep). Both
-- engines call AutoWifi:withWifi(), which restores wifi asynchronously; on
-- Kobo (and likely similar elsewhere) isWifiOn() flips true the instant the
-- restore is kicked off, well before the connection actually completes. So
-- whichever engine goes first triggers the restore and then waits on the
-- async connectivity check, while the second engine sees "wifi already on"
-- and links synchronously. If the retry chain in startReadCache checks
-- bookLinked() immediately after calling tryAutolink() instead of waiting
-- for it to actually finish, the first engine's chain dies silently and its
-- periodic sync trigger (process_page_turns) never gets armed. Since
-- pairs(main.lua's engines table) deterministically visits "hardcover"
-- before "storygraph" under LuaJIT, this bug always hit Hardcover in
-- practice and never StoryGraph -- hence testing both orderings here.

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr, Clock = mocks.UIManager, mocks.NetworkMgr, mocks.Clock

local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local HardcoverBusiness = require("shelfsync/lib/hardcover/business")
local StoryGraphBusiness = require("shelfsync/lib/storygraph/business")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")
local HARDCOVER_CONST = require("shelfsync/lib/hardcover/constants")
local STORYGRAPH_CONST = require("shelfsync/lib/storygraph/constants")

describe("SyncEngine autolink race (StoryGraph + Hardcover sharing one wifi restore)", function()
  local ui, doc_settings

  before_each(function()
    mocks.reset()

    doc_settings = mocks.makeStore()
    ui = {
      document = {
        file = "/books/test.epub",
        getProps = function()
          return { title = "Test Book", authors = "Test Author", identifiers = "isbn:1234567890123" }
        end,
      },
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      getCurrentPage = function() return 1 end,
      doc_settings = doc_settings,
    }
  end)

  -- Mirrors main.lua's _buildEngine, trimmed to what startReadCache /
  -- tryAutolink actually touch.
  local function buildEngine(label, settings_class, filename, business_class, constants)
    local settings = settings_class:new("/settings/" .. filename, ui, nil)
    settings:updateSetting(SETTING.LINK_BY_ISBN, true)
    settings:updateSetting(SETTING.LINK_BY_TITLE, true)
    settings:updateSetting(SETTING.ENABLE_WIFI, true)

    local state = { page = nil, pos = nil, search_results = {}, book_status = {} }
    local wifi = AutoWifi:new { settings = settings, label = label }

    local user = { getId = function() return 1 end }
    local api = {
      findBookByIdentifiers = function(_, identifiers, user_id)
        mocks.log("[" .. label .. "] api:findBookByIdentifiers called at t=" .. Clock.now)
        return { book_id = 42, title = "Test Book", pages = 300 }
      end,
      findBooks = function(_, title, authors, user_id)
        return { { book_id = 42, title = "Test Book", pages = 300 } }
      end,
      updateUserBook = function() return { status_id = 1 } end,
      findUserBook = function() return { id = 42, status_id = 1 } end,
    }
    local cache = {
      cacheUserBook = function() state.book_status = { status_id = 1, id = 42 } end,
    }
    local dialog_manager = {}

    local business = business_class:new {
      api = api, user = user, cache = cache, dialog_manager = dialog_manager,
      settings = settings, state = state, ui = ui, wifi = wifi,
    }

    return SyncEngine:new {
      label = label,
      constants = constants,
      highlight_menu_name = "hl_" .. label,
      auth_setting_key = label .. "_auth",
      api = api, user = user, cache = cache,
      page_mapper = { cachePageMap = function() end },
      wifi = wifi, dialog_manager = dialog_manager,
      business = business, settings = settings,
      plugin_settings = settings,
      ui = ui, view = {}, state = state,
    }
  end

  -- pairs() iteration order over main.lua's engines table is hash-dependent,
  -- not something the plugin controls -- what matters is that the OUTCOME
  -- doesn't depend on which engine happens to go first, so both orderings
  -- are exercised as separate cases below.
  local function runScenario(engines_in_order)
    NetworkMgr._wifi_on = false
    NetworkMgr._connected = false

    for _, engine in ipairs(engines_in_order) do
      engine:onReaderReady()
    end

    UIManager:_runUntilIdle()
  end

  describe("when wifi starts off", function()
    it("links and arms periodic sync for both engines when Hardcover goes first", function()
      local hardcover = buildEngine("Hardcover", HardcoverSettings, "hardcover.lua", HardcoverBusiness, HARDCOVER_CONST)
      local storygraph = buildEngine("StoryGraph", StoryGraphSettings, "storygraph.lua", StoryGraphBusiness, STORYGRAPH_CONST)

      runScenario({ hardcover, storygraph })

      assert.is_true(hardcover.settings:bookLinked())
      assert.is_true(hardcover.state.process_page_turns)
      assert.is_true(storygraph.settings:bookLinked())
      assert.is_true(storygraph.state.process_page_turns)
    end)

    it("links and arms periodic sync for both engines when StoryGraph goes first", function()
      local storygraph = buildEngine("StoryGraph", StoryGraphSettings, "storygraph.lua", StoryGraphBusiness, STORYGRAPH_CONST)
      local hardcover = buildEngine("Hardcover", HardcoverSettings, "hardcover.lua", HardcoverBusiness, HARDCOVER_CONST)

      runScenario({ storygraph, hardcover })

      assert.is_true(storygraph.settings:bookLinked())
      assert.is_true(storygraph.state.process_page_turns)
      assert.is_true(hardcover.settings:bookLinked())
      assert.is_true(hardcover.state.process_page_turns)
    end)

    it("restores wifi only once and waits for real connectivity before both engines' attempts", function()
      -- NetworkMgr:isWifiOn() flips true the instant restoreWifiAsync() is
      -- called, well before the connection actually completes (see
      -- koreader_mocks' CONNECT_DELAY). A caller that lets a second engine's
      -- withWifi() treat that early flip as "already connected" would try
      -- its real API call against a connection that doesn't exist yet.
      local restore_calls = 0
      local real_restore = NetworkMgr.restoreWifiAsync
      NetworkMgr.restoreWifiAsync = function(...)
        restore_calls = restore_calls + 1
        return real_restore(...)
      end

      local hardcover = buildEngine("Hardcover", HardcoverSettings, "hardcover.lua", HardcoverBusiness, HARDCOVER_CONST)
      local storygraph = buildEngine("StoryGraph", StoryGraphSettings, "storygraph.lua", StoryGraphBusiness, STORYGRAPH_CONST)

      runScenario({ hardcover, storygraph })

      NetworkMgr.restoreWifiAsync = real_restore

      assert.are.equal(1, restore_calls)

      local hardcover_call_at, storygraph_call_at
      for _, line in ipairs(mocks.LOG) do
        local t = line:match("^%[Hardcover%] api:findBookByIdentifiers called at t=(%d+)")
        if t then hardcover_call_at = tonumber(t) end
        t = line:match("^%[StoryGraph%] api:findBookByIdentifiers called at t=(%d+)")
        if t then storygraph_call_at = tonumber(t) end
      end

      -- Both engines' real API calls should land on the exact same tick --
      -- the moment the shared connectivity check actually succeeds -- and
      -- strictly after wifi's interface-up instant (t=1), not at it.
      assert.are.equal(hardcover_call_at, storygraph_call_at)
      assert.is_true(hardcover_call_at > 1)
    end)
  end)
end)
