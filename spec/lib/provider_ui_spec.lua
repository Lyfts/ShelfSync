require("spec.support.koreader_mocks")
package.loaded["ui/widget/spinwidget"] = { new = function(_, o) return o end }

local LibraryThingAccount = require("shelfsync/lib/librarything/account_ui")

describe("Provider dashboard actions", function()
  it("exposes the account controls for every registered service", function()
    for _, key in ipairs({ "storygraph", "hardcover", "goodreads", "fable", "pagebound", "librarything" }) do
      local account = require("shelfsync/lib/" .. key .. "/account_ui")
      local items = account.items({})
      assert.is_true(#items > 0, key)
    end
  end)

  it("keeps provider book actions free of progress editors", function()
    for _, key in ipairs({ "storygraph", "hardcover" }) do
      local actions = require("shelfsync/lib/" .. key .. "/book_actions")
      local engine = { state = { book_status = { status_id = "reading" } } }
      for _, item in ipairs(actions.items(engine)) do
        local text = item.text or (item.text_func and item.text_func()) or ""
        assert.is_nil(text:find("Update progress", 1, true), key)
        assert.is_nil(text:find("Update page", 1, true), key)
      end
    end
  end)

  it("keeps Pagebound's forum note action with the current progress", function()
    local actions = require("shelfsync/lib/pagebound/book_actions")
    local captured
    local engine = {
      state = { book_status = {} },
      ui = { document = {}, getCurrentPage = function() return 42 end },
      settings = { pages = function() return 200 end, bookLinked = function() return true end },
      provider = { getRemotePercent = function() return 25 end },
      isActive = function() return true end,
      dialog_manager = { journalEntryForm = function(_, ...) captured = { ... } end },
    }
    local items = actions.items(engine)
    assert.equals(1, #items)
    assert.equals("Add forum note", items[1].text)
    items[1].callback()
    assert.equals(42, captured[3])
    assert.equals(25, captured[6])
    assert.equals("note", captured[7])
    assert.is_true(captured[8])
  end)

  it("drops the book-action modules that only held progress editors", function()
    for _, key in ipairs({ "goodreads", "fable" }) do
      local loaded = pcall(require, "shelfsync/lib/" .. key .. "/book_actions")
      assert.is_false(loaded, key)
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
