local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager

-- Capture the SearchDialog options and provide just the mutators this class
-- uses, without loading KOReader's widget tree.
local original_search_dialog = package.loaded["shelfsync/lib/common/ui/search_dialog"]
local SearchDialog = {}
function SearchDialog.new(_, options)
  function options:setItems(title, items, active_item, search_value)
    self.title = title
    self.items = items
    self.active_item = active_item
    self.search_value = search_value
  end
  function options:setActiveTab(key) self.active_tab = key end
  function options:onClose()
    if self.close_callback then self.close_callback() end
  end
  return options
end
package.loaded["shelfsync/lib/common/ui/search_dialog"] = SearchDialog
local ManualLinkDialog = require("shelfsync/lib/common/manual_link_dialog")
package.loaded["shelfsync/lib/common/ui/search_dialog"] = original_search_dialog

local providers = {
  { key = "storygraph", label = "StoryGraph" },
  { key = "hardcover", label = "Hardcover" },
  { key = "goodreads", label = "Goodreads" },
  { key = "fable", label = "Fable" },
  { key = "pagebound", label = "Pagebound" },
}

local LINK_FIELDS = {
  storygraph = { "book_id", "edition_id", "edition_format", "pages", "title", "link_method" },
  hardcover = { "book_id", "edition_id", "edition_format", "pages", "title", "link_method" },
  goodreads = { "book_id", "edition_id", "pages", "title", "link_method" },
  fable = { "book_id", "pages", "title", "link_method" },
  pagebound = { "book_id", "book_uuid", "pages", "title", "link_method" },
}

local function makeEngine(key)
  local state = { linked = false, active = true, linked_book_id = nil, searches = {}, seed_calls = 0, linked_books = {} }
  local engine = {
    label = key,
    enabled = true,
    plugin_settings = { readSetting = function() return false end },
    settings = {
      bookLinked = function() return state.linked end,
      getLinkedBookId = function() return state.linked_book_id end,
      providerEnabled = function() return true end,
      updateBookSetting = function(_, file, change)
        table.insert(state.linked_books, { file = file, change = change })
        state.linked = false
        state.linked_book_id = nil
      end,
    },
    api = {
      hasCredential = function() return true end,
      findBooks = function(_, query)
        table.insert(state.searches, query)
        if state.search_error then return {}, state.search_error end
        return { { book_id = key .. "-result", title = key .. " result", contributions = {} } }
      end,
    },
    provider = {
      findBookOptions = function(_, already_linked)
        state.seed_calls = state.seed_calls + 1
        return already_linked and "linked" or "initial", {
          { book_id = key .. "-seed", title = key .. " seed", contributions = {} },
        }
      end,
      linkBookManually = function(_, book)
        state.linked = true
        state.linked_book_id = book.book_id
        table.insert(state.linked_books, book)
        return true
      end,
      getLinkedBookLabel = function() return key .. " linked book" end,
    },
    user = { getId = function() return 17 end },
  }
  function engine:isActive() return state.active end
  function engine:isWikipediaDocument() return false end
  return engine, state
end

local function makeEngines()
  local engines, states = {}, {}
  for _, provider in ipairs(providers) do
    engines[provider.key], states[provider.key] = makeEngine(provider.key)
  end
  return engines, states
end

describe("ManualLinkDialog provider tabs", function()
  local original_show, shown

  before_each(function()
    mocks.reset()
    shown = {}
    original_show = UIManager.show
    UIManager.show = function(_, dialog) table.insert(shown, dialog) end
  end)

  after_each(function()
    UIManager.show = original_show
  end)

  it("keeps tab searches and saved links scoped to the selected provider", function()
    local engines, states = makeEngines()
    states.hardcover.linked = true
    states.hardcover.linked_book_id = "saved-hardcover"
    local changed = {}
    local dialog = ManualLinkDialog:new {
      providers = providers,
      engines = engines,
      ui = { document = { file = "/books/test.epub" } },
    }

    dialog:show(nil, function(provider, book) table.insert(changed, { provider = provider.key, book = book }) end)

    local widget = shown[1]
    assert.equals(5, #widget.tab_items)
    assert.equals("storygraph", widget.active_tab)
    assert.equals("StoryGraph", widget.tab_items[1].text_func())
    assert.equals("Hardcover ✓", widget.tab_items[2].text_func())
    assert.equals("storygraph-seed", widget.items[1].book_id)

    widget.tab_callback("goodreads")
    assert.equals("goodreads", widget.active_tab)
    assert.equals("goodreads-seed", widget.items[1].book_id)
    widget.search_callback("Goodreads title")
    assert.same({ "Goodreads title" }, states.goodreads.searches)
    assert.equals("goodreads-result", widget.items[1].book_id)

    widget.tab_callback("storygraph")
    assert.equals("storygraph-seed", widget.items[1].book_id)
    assert.equals("goodreads-result", dialog.provider_data.goodreads.items[1].book_id)

    widget.tab_callback("goodreads")
    local selected_book = { book_id = "goodreads-manual", title = "Manual choice" }
    widget.select_book_cb(selected_book)
    assert.equals("goodreads-manual", states.goodreads.linked_book_id)
    assert.equals("goodreads", changed[#changed].provider)
    assert.equals(selected_book, changed[#changed].book)
    assert.equals("goodreads-manual", widget.active_item.book_id)

    widget.footer_items[1].hold_callback()
    assert.same({
      file = "/books/test.epub",
      change = { _delete = LINK_FIELDS.goodreads },
    }, states.goodreads.linked_books[#states.goodreads.linked_books])
    assert.is_false(states.goodreads.linked)
    assert.equals("goodreads", changed[#changed].provider)
    assert.is_nil(changed[#changed].book)
  end)

  it("surfaces search errors and avoids keeping failed results in the tab cache", function()
    local engines, states = makeEngines()
    states.goodreads.search_error = "temporary network failure"
    local dialog = ManualLinkDialog:new {
      providers = providers,
      engines = engines,
      ui = { document = { file = "/books/test.epub" } },
    }

    dialog:show("goodreads")
    local widget = shown[1]
    widget.search_callback("title")

    assert.is_nil(dialog.provider_data.goodreads)
    assert.equals(2, #shown) -- the dialog and the search error message
    assert.equals("notice-warning", shown[2].icon)
    assert.is_table(widget.items)
    assert.equals(0, #widget.items)
  end)
end)
