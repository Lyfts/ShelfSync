require("spec.support.koreader_mocks")

local LibraryThingAccount = require("shelfsync/lib/librarything/account_ui")

describe("Provider dashboard actions", function()
  it("exposes the account controls for every registered service", function()
    for _, key in ipairs({ "storygraph", "hardcover", "goodreads", "fable", "pagebound", "librarything" }) do
      local account = require("shelfsync/lib/" .. key .. "/account_ui")
      local items = account.items({})
      assert.is_true(#items > 0, key)
    end
  end)

  it("opens each reading service's progress form with its remote position", function()
    for _, key in ipairs({ "goodreads", "fable", "pagebound" }) do
      local constants = require("shelfsync/lib/" .. key .. "/constants")
      local actions = require("shelfsync/lib/" .. key .. "/book_actions")
      local captured
      local engine = {
        state = { book_status = { status_id = constants.STATUS.READING } },
        ui = { document = {}, getCurrentPage = function() return 42 end },
        settings = { pages = function() return 200 end },
        provider = { getRemotePercent = function() return 25 end },
        dialog_manager = { journalEntryForm = function(_, ... ) captured = { ... } end },
      }
      local items = actions.items(engine)
      assert.equals(1, #items)
      items[1].callback()
      assert.equals(42, captured[3])
      assert.equals(200, captured[4])
      assert.equals(25, captured[6])
      assert.equals("note", captured[7])
      engine.state.book_status.status_id = constants.STATUS.FINISHED
      assert.equals(0, #actions.items(engine))
    end
  end)

  it("refreshes LibraryThing collections and updates the open settings menu", function()
    local refreshed, updated = false, false
    local engine = {
      provider = { wifi = { withWifi = function(_, callback) callback(true) end } },
      api = {
        collectionId = function(_, id) return id end,
        collections = function() return {} end,
        refreshCollections = function() refreshed = true return {} end,
      },
    }
    local menu = { item_table = {}, updateItems = function() updated = true end }
    local items = LibraryThingAccount.getReadCollectionItems(engine)
    items[#items].callback(menu)
    assert.is_true(refreshed)
    assert.is_true(updated)
    assert.equals(1, #menu.item_table)
  end)
end)
