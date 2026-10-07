local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager

-- These widgets are only constructed by action callbacks, which this spec
-- doesn't invoke. Stub them so the shared status menu can load outside KOReader.
local original_spin_widget = package.loaded["ui/widget/spinwidget"]
local original_double_spin = package.loaded["shelfsync/lib/common/ui/update_double_spin_widget"]
package.loaded["ui/widget/spinwidget"] = { new = function(_, o) return o end }
package.loaded["shelfsync/lib/common/ui/update_double_spin_widget"] = { new = function(_, o) return o end }
local UpdateStatusMenu = require("shelfsync/lib/common/update_status_menu")
package.loaded["ui/widget/spinwidget"] = original_spin_widget
package.loaded["shelfsync/lib/common/ui/update_double_spin_widget"] = original_double_spin

local ProviderSettingsMenu = require("shelfsync/lib/common/provider_settings_menu")
local AccountsMenu = require("shelfsync/lib/common/accounts_menu")
local STORYGRAPH = require("shelfsync/lib/storygraph/constants")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local FABLE = require("shelfsync/lib/fable/constants")
local PAGEBOUND = require("shelfsync/lib/pagebound/constants")

local providers = {
  { key = "storygraph", label = "StoryGraph", prefix = "StoryGraph", constants = STORYGRAPH },
  { key = "hardcover", label = "Hardcover", prefix = "Hardcover", constants = HARDCOVER },
  { key = "goodreads", label = "Goodreads", prefix = "Goodreads", constants = GOODREADS },
  { key = "fable", label = "Fable", prefix = "Fable", constants = FABLE },
  { key = "pagebound", label = "Pagebound", prefix = "Pagebound", constants = PAGEBOUND },
}

local function findItem(items, text)
  for _, item in ipairs(items) do
    if item.text == text then return item end
  end
end

local function makeEngine(key)
  local state = {
    provider_enabled = true,
    sync_enabled = false,
    linked = true,
    active = true,
    credential = false,
    edition_format = nil,
    edition_id = nil,
    book_id = key .. "-book",
    cache_updates = 0,
    status_updates = 0,
    book_removals = 0,
    connection_checks = 0,
    edition_dialogs = 0,
    suggestions = 0,
    linked_updates = {},
  }
  local engine = {
    label = key,
    enabled = true,
    plugin_settings = { readSetting = function() return false end },
    settings = {
      providerEnabled = function() return state.provider_enabled end,
      setProviderEnabled = function(_, value) state.provider_enabled = value end,
      syncEnabled = function() return state.sync_enabled end,
      setSync = function(_, value) state.sync_enabled = value end,
      bookLinked = function() return state.linked end,
      getLinkedEditionFormat = function() return state.edition_format end,
      getLinkedEditionId = function() return state.edition_id end,
      getLinkedBookId = function() return state.book_id end,
      getLinkedBookLabel = function() return key .. " linked book" end,
      updateBookSetting = function(_, file, change)
        table.insert(state.linked_updates, { file = file, change = change })
        state.linked = false
      end,
      pages = function() return 300 end,
      syncByRemotePages = function() return false end,
    },
    api = {
      hasCredential = function() return state.credential end,
      findBooks = function() return {} end,
      findEditions = function() return {} end,
      testConnection = function()
        state.connection_checks = state.connection_checks + 1
        return { ok = true, user_id = 7 }
      end,
    },
    provider = {
      showChangeEditionDialog = function() state.edition_dialogs = state.edition_dialogs + 1 end,
      showRandomBookDialog = function() state.suggestions = state.suggestions + 1 end,
    },
    cache = { cacheUserBook = function() state.cache_updates = state.cache_updates + 1 end },
    wifi = { withWifi = function(_, callback) callback(false, nil) end },
    state = { book_status = {} },
    ui = { document = { file = "/books/test.epub" }, getCurrentPage = function() return 10 end },
    user = { getId = function() return 7 end },
    dialog_manager = {
      maybeConfirm = function(_, options) options.ok_callback() end,
    },
    page_mapper = {},
  }
  function engine.cache:queueBookStatus(_filename, status, callback)
    state.status_updates = state.status_updates + 1
    engine.state.book_status = { id = key .. "-status", status_id = status }
    if callback then callback(true) end
  end
  function engine.cache:queueBookRemoval(_filename, callback)
    state.book_removals = state.book_removals + 1
    engine.state.book_status = {}
    if callback then callback(true) end
  end
  function engine:isActive() return state.active end
  return engine, state
end

local function makeEngines()
  local engines, states = {}, {}
  for _, provider in ipairs(providers) do
    engines[provider.key], states[provider.key] = makeEngine(provider.key)
  end
  return engines, states
end

describe("unified provider menus", function()
  before_each(function() mocks.reset() end)

  it("keeps document-only controls out of Provider settings without an open book", function()
    local engines = makeEngines()
    local menu = ProviderSettingsMenu:new {
      providers = providers,
      engines = engines,
      ui = { document = nil },
      manual_link_dialog = {},
      update_status_menu = { menuItem = function() return { text = "Update status" } end },
    }

    local items = menu:getSubMenuItems()
    assert.is_truthy(findItem(items, "Enable or disable providers"))
    assert.is_nil(findItem(items, "Book linking"))
    assert.is_nil(findItem(items, "Automatically track progress"))
    assert.is_nil(findItem(items, "Jump to linked book position"))
    assert.is_nil(findItem(items, "Update status"))
    assert.is_truthy(findItem(items, "Hardcover options"))
  end)

  it("keeps common controls, provider-specific options, and live enablement together", function()
    local engines, states = makeEngines()
    local manual_link_calls, menu_updates = 0, 0
    local menu = ProviderSettingsMenu:new {
      providers = providers,
      engines = engines,
      ui = { document = { file = "/books/test.epub" } },
      manual_link_dialog = {
        show = function(_, provider_key, callback)
          assert.is_nil(provider_key)
          manual_link_calls = manual_link_calls + 1
          callback()
        end,
      },
      update_status_menu = { menuItem = function() return { text = "Update status" } end },
    }
    local menu_instance = { updateItems = function() menu_updates = menu_updates + 1 end }
    local items = menu:getSubMenuItems()

    local enable_menu = findItem(items, "Enable or disable providers")
    assert.equals(5, #enable_menu.sub_item_table)
    assert.is_true(enable_menu.sub_item_table[1].checked_func())
    enable_menu.sub_item_table[1].callback()
    assert.is_false(states.storygraph.provider_enabled)

    local link_item = findItem(items, "Link or relink book")
    link_item.callback(menu_instance)
    assert.equals(1, manual_link_calls)
    assert.equals(1, menu_updates)

    local tracking = findItem(items, "Automatically track progress")
    local goodreads_tracking = tracking.sub_item_table[3]
    assert.is_true(goodreads_tracking.enabled_func())
    assert.is_false(goodreads_tracking.checked_func())
    goodreads_tracking.callback()
    assert.is_true(states.goodreads.sync_enabled)
    states.goodreads.active = false
    assert.is_false(goodreads_tracking.enabled_func())

    local storygraph_options = findItem(items, "StoryGraph options")
    assert.equals("Change edition", storygraph_options.sub_item_table[1].text_func())
    local hardcover_options = findItem(items, "Hardcover options")
    assert.equals("Change edition", hardcover_options.sub_item_table[1].text_func())
    assert.equals("Suggest a book", hardcover_options.sub_item_table[2].text)
    assert.is_truthy(findItem(items, "Update status"))
  end)

  it("shows five account submenus with a live credential indicator and no sync gate", function()
    local engines, states = makeEngines()
    local menu = AccountsMenu:new { providers = providers, engines = engines }
    local items = menu:getSubMenuItems()

    assert.equals(5, #items)
    for index, provider in ipairs(providers) do
      local item = items[index]
      assert.equals(provider.label, item.text_func())
      assert.is_nil(item.enabled_func)
      assert.is_true(#item.sub_item_table_func() > 0)
      states[provider.key].credential = true
      assert.equals(provider.label .. " ✓", item.text_func())
      states[provider.key].active = false
      assert.equals(provider.label .. " ✓", item.text_func())
    end
  end)

  it("keeps the Goodreads connection check in Accounts", function()
    local engines, states = makeEngines()
    local menu = AccountsMenu:new { providers = providers, engines = engines }
    local goodreads_items = menu:getSubMenuItems()[3].sub_item_table_func()
    local test_connection = findItem(goodreads_items, "Test connection")

    assert.is_truthy(test_connection)
    test_connection.callback()
    assert.equals(1, states.goodreads.connection_checks)
  end)

  it("gates Update status by document, provider activation, and saved book link", function()
    local engines, states = makeEngines()
    local ui = { document = { file = "/books/test.epub" } }
    local menu = UpdateStatusMenu:new { providers = providers, engines = engines, ui = ui }
    local root_item = menu:menuItem()

    for provider_key, state in pairs(states) do
      if provider_key ~= "storygraph" then
        state.active = false
      end
    end

    assert.is_true(root_item.enabled_func())
    assert.equals(11, #menu:getSubMenuItems())
    assert.is_true(menu:getSubMenuItems()[1].enabled_func())

    states.storygraph.active = false
    assert.is_false(menu:getSubMenuItems()[1].enabled_func())
    states.storygraph.active = true
    states.storygraph.linked = false
    assert.is_false(menu:getSubMenuItems()[1].enabled_func())
    states.storygraph.linked = true

    local link_status_item = findItem(menu:getSubMenuItems(), "Link Status")
    assert.equals(5, #link_status_item.sub_item_table_func())
    assert.equals(0, states.storygraph.cache_updates)

    ui.document = nil
    assert.is_false(root_item.enabled_func())
    assert.equals(0, #menu:getSubMenuItems())
  end)

  it("routes shared status changes through each provider's serialized cache write", function()
    local engines, states = makeEngines()
    local menu = UpdateStatusMenu:new {
      providers = providers,
      engines = engines,
      ui = { document = { file = "/books/test.epub" } },
    }

    menu:getSubMenuItems()[1].callback({ updateItems = function() end })

    for _, provider in ipairs(providers) do
      assert.equals(1, states[provider.key].status_updates)
    end
  end)

  it("routes shared removals through each provider's queued cache path", function()
    local engines, states = makeEngines()
    for _, provider in ipairs(providers) do
      engines[provider.key].state.book_status = {
        id = provider.key .. "-status",
        status_id = provider.constants.STATUS.READING,
      }
    end
    local menu = UpdateStatusMenu:new {
      providers = providers,
      engines = engines,
      ui = { document = { file = "/books/test.epub" } },
    }

    local remove_item
    for _, item in ipairs(menu:getSubMenuItems()) do
      if item.text and item.text:find("Remove from providers", 1, true) then
        remove_item = item
        break
      end
    end
    local checklist = remove_item.sub_item_table_func()
    local menu_instance = { updateItems = function() end }
    for i = 1, #providers do
      checklist[i].callback(menu_instance)
    end
    checklist[#checklist].callback(menu_instance)

    for _, provider in ipairs(providers) do
      assert.equals(1, states[provider.key].book_removals)
    end
  end)
end)
