require("spec.support.koreader_mocks")

local original_providers = package.loaded["shelfsync/lib/common/constants/providers"]
local original_menus = package.loaded["shelfsync/lib/common/ui/dashboard_menus"]
local providers = {
  { key = "one", label = "One" }, { key = "two", label = "Two" },
}
for _, provider in ipairs(providers) do
  provider.account_ui = { items = function() return { { text = "Account" } } end }
  provider.book_actions = { items = function() return {} end }
end
package.loaded["shelfsync/lib/common/constants/providers"] = providers
package.loaded["shelfsync/lib/common/ui/dashboard_menus"] = nil
local Menus = require("shelfsync/lib/common/ui/dashboard_menus")
package.loaded["shelfsync/lib/common/constants/providers"] = original_providers
package.loaded["shelfsync/lib/common/ui/dashboard_menus"] = original_menus

describe("Dashboard service controls", function()
  local app, states
  before_each(function()
    states = { one = { enabled = true, linked = true, tracking = false },
      two = { enabled = false, linked = true, tracking = false } }
    app = { engines = {} }
    for _, provider in ipairs(providers) do
      local state = states[provider.key]
      state.book_id = provider.key .. "-id"
      local engine = {
        settings = {
          providerEnabled = function() return state.enabled end,
          setProviderEnabled = function(_, value) state.enabled = value end,
          bookLinked = function() return state.linked end,
          syncEnabled = function() return state.tracking end,
          setSync = function(_, value) state.tracking = value end,
          readBookSetting = function() return state.book_id end,
        },
        api = { hasCredential = function() return true end },
      }
      function engine:isActive() return state.enabled end
      app.engines[provider.key] = engine
    end
  end)

  it("keeps account access available for disabled services", function()
    local sections = Menus.connections(app)
    local accounts = sections[2].sub_item_table
    assert.equals("Account", accounts[2].sub_item_table_func()[1].text)
    local enabled = sections[1].sub_item_table
    enabled[2].callback()
    assert.is_true(states.two.enabled)
  end)

  it("changes tracking only for active linked services", function()
    local items = Menus.tracking(app)
    items[1].callback()
    assert.is_true(states.one.tracking)
    assert.is_false(states.two.tracking)
    assert.is_false(items[4].enabled_func())
    items[2].callback()
    assert.is_false(states.one.tracking)
  end)

  it("loads service-specific book actions directly", function()
    local engine = app.engines.one
    local cached = false
    engine.cache = { cacheUserBook = function() cached = true end }
    providers[1].book_actions.items = function(received)
      assert.equals(engine, received)
      return { { text = "Service-only option" } }
    end
    local options = Menus.bookOptions(app)[4].sub_item_table[1].sub_item_table_func()
    assert.is_true(cached)
    assert.equals(1, #options)
    assert.equals("Service-only option", options[1].text)
  end)

  it("removes only selected services and reports partial failures", function()
    local UIManager = require("ui/uimanager")
    local original_show, message = UIManager.show
    UIManager.show = function(_, dialog) message = dialog.text end
    app.ui = { document = { file = "/book.epub" } }
    local removed = {}
    for _, provider in ipairs(providers) do
      local key, engine = provider.key, app.engines[provider.key]
      engine.label = provider.label
      engine.dialog_manager = { maybeConfirm = function(_, options) options.ok_callback() end }
      engine.cache = { queueBookRemoval = function(_, file, callback)
        table.insert(removed, { key = key, file = file })
        callback(key == "one")
      end }
    end
    states.two.enabled = true
    local items = Menus.bookOptions(app)[1].sub_item_table_func()
    items[1].callback()
    items[2].callback()
    items[3].callback()
    UIManager.show = original_show
    assert.same({ { key = "one", file = "/book.epub" }, { key = "two", file = "/book.epub" } }, removed)
    assert.matches("Removed from: One", message)
    assert.matches("Could not remove from: Two", message)
  end)

  it("does not remove a replacement link after confirmation was shown", function()
    local UIManager = require("ui/uimanager")
    local original_show, confirm, removed = UIManager.show, nil, false
    UIManager.show = function() end
    app.ui = { document = { file = "/book.epub" } }
    local engine = app.engines.one
    engine.label = "One"
    engine.dialog_manager = { maybeConfirm = function(_, options) confirm = options.ok_callback end }
    engine.cache = { queueBookRemoval = function() removed = true end }
    local items = Menus.bookOptions(app)[1].sub_item_table_func()
    items[1].callback()
    items[3].callback()
    states.one.book_id = "new-link"
    confirm()
    UIManager.show = original_show
    assert.is_false(removed)
  end)
end)
