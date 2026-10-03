-- Regression tests for automatically adding a book to Currently Reading.
-- That's only safe once the provider has confirmed the book isn't on any of
-- the user's shelves. A failed lookup, a Goodreads page whose shelf can't be
-- read, or a Goodreads shelf that doesn't map to a status must leave the
-- remote status alone, both when linking a book and when an already-linked
-- book is opened (startReadCache).

local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr = mocks.UIManager, mocks.NetworkMgr

-- Busted supplies dkjson; preserve null like KOReader's json decoder does.
local json = require("dkjson")
package.loaded.json = {
  decode = function(text)
    local data, _, err = json.decode(text, 1, json.null)
    if err then error(err) end
    return data
  end,
  util = { null = json.null },
}
package.loaded["shelfsync/lib/goodreads/api"] = nil

-- StoryGraph's api.lua captures htmlparser when it's first required, so it's
-- dropped from the module cache to make sure it picks up this stub. `links` is
-- what root:select("a") returns, for StoryGraph's other-edition check.
local links = {}
package.loaded.htmlparser = {
  parse = function()
    return {
      select = function(_, selector)
        return selector == "a" and links or {}
      end,
    }
  end,
}
package.loaded["shelfsync/lib/storygraph/api"] = nil

local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local STATUS = require("shelfsync/lib/common/constants/status").STATUS
local GoodreadsApi = require("shelfsync/lib/goodreads/api")
local GoodreadsProvider = require("shelfsync/lib/goodreads/provider")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local HardcoverApi = require("shelfsync/lib/hardcover/api")
local HardcoverProvider = require("shelfsync/lib/hardcover/provider")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local StoryGraphApi = require("shelfsync/lib/storygraph/api")
local StoryGraphProvider = require("shelfsync/lib/storygraph/provider")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")
local FableApi = require("shelfsync/lib/fable/api")
local FableProvider = require("shelfsync/lib/fable/provider")
local FableSettings = require("shelfsync/lib/fable/settings")
local PageboundApi = require("shelfsync/lib/pagebound/api")
local PageboundProvider = require("shelfsync/lib/pagebound/provider")
local PageboundSettings = require("shelfsync/lib/pagebound/settings")

local FILE = "/books/test.epub"

-- Trimmed-down Goodreads book page Apollo cache, in the shape findUserBook
-- parses: ROOT_QUERY points to the page's own Book entry, whose viewerShelving
-- is either null or a "__ref" to a Shelving object stored elsewhere in the same
-- dump under that ref as its key. Other books (series, recommendations) have
-- Book entries of their own. The page's own book is always kca://book/1.
local function shelvingRef(n)
  return ([[Shelving:{\"book\":\"kca://book/%d\",\"user\":{\"id\":1}}]]):format(n)
end

local function onShelf(n)
  return [[{"__ref":"]] .. shelvingRef(n) .. [["}]]
end

local function bookEntry(n, viewer_shelving)
  return ([["Book:kca://book/%d":{"__typename":"Book","legacyId":%d,"viewerShelving":]]):format(n, n)
    .. viewer_shelving .. [[,"details":{"__typename":"BookDetails","numPages":320}}]]
end

local function shelvingEntry(n, shelf_name)
  return [["]] .. shelvingRef(n) .. [[":{"__typename":"Shelving",]]
    .. [["shelf":{"__typename":"Shelf","name":"]] .. shelf_name .. [["}}]]
end

local function page(entries, root_entries)
  return [[<script>{"ROOT_QUERY":{"__typename":"Query",]]
    .. (root_entries or [["getBookByLegacyId({\"legacyId\":\"1\"})":{"__ref":"Book:kca://book/1"}]]) .. "},"
    .. table.concat(entries, ",") .. "}</script>"
end

local function shelvedPage(shelf_name)
  return page({ bookEntry(1, onShelf(1)), shelvingEntry(1, shelf_name) })
end

local UNSHELVED_PAGE = page({ bookEntry(1, "null") })

-- Served with HTTP 200 but the book has no viewerShelving at all, e.g. after a
-- layout change.
local UNREADABLE_PAGE = page({ [["Book:kca://book/1":{"__typename":"Book","legacyId":1}]] })

describe("Automatic Currently Reading after a status lookup", function()
  local ui, response, writes, shown

  before_each(function()
    mocks.reset()
    ui = {
      document = {
        file = FILE,
        getProps = function() return { title = "Test Book", authors = "Test Author" } end,
      },
      highlight = {
        addToHighlightDialog = function() end,
        removeFromHighlightDialog = function() end,
      },
      doc_settings = mocks.makeStore(),
    }
    response = { 200, UNSHELVED_PAGE }
    links = {}
    writes = {}
    shown = {}
    stub(UIManager, "show", function(_, widget) table.insert(shown, widget) end)
  end)

  after_each(function()
    mock.revert(UIManager)
  end)

  local function recordWrite(_, book_id, status_id)
    table.insert(writes, status_id)
    return { id = book_id, book_id = book_id, status_id = status_id }
  end

  local function goodreadsApi(settings)
    return setmetatable({
      settings = settings,
      requests = 0,
      hasCredential = function() return true end,
      request = function(self)
        self.requests = self.requests + 1
        return response[1], response[2]
      end,
      updateUserBook = recordWrite,
    }, { __index = GoodreadsApi })
  end

  local function buildProvider(provider_class, settings, api)
    local state = { book_status = {} }
    local user = { getId = function() return 1 end }
    local cache = Cache:new { api = api, user = user, settings = settings, state = state, ui = ui }
    return provider_class:new {
      label = "Provider",
      api = api, user = user, cache = cache, dialog_manager = {},
      settings = settings, state = state, ui = ui,
    }
  end

  describe("GoodreadsApi:findUserBook", function()
    local api

    before_each(function()
      api = goodreadsApi(GoodreadsSettings:new("/settings/goodreads.lua", ui, nil))
    end)

    it("reports a book with no viewer shelving as not shelved", function()
      local status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.is_nil(status.status_id)
      assert.is_false(status.shelved)
      assert.are.equal(320, status.page_count)
    end)

    it("maps a recognized shelf to its status", function()
      response = { 200, shelvedPage("read") }
      local status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.are.equal(STATUS.FINISHED, status.status_id)
      assert.is_true(status.shelved)
    end)

    it("reports an unrecognized shelf as shelved without a status", function()
      response = { 200, shelvedPage("read_later") }
      local status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.is_nil(status.status_id)
      assert.is_true(status.shelved)
      assert.are.equal("read_later", status.shelf)
    end)

    it("reads the shelf of the page's own book, not of other books on the page", function()
      response = { 200, page({
        (bookEntry(2, "null"):gsub('"numPages":320', '"numPages":17')),
        bookEntry(1, onShelf(1)),
        shelvingEntry(1, "read"),
      }) }
      local status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.are.equal(STATUS.FINISHED, status.status_id)
      assert.are.equal(320, status.page_count)

      response = { 200, page({
        bookEntry(2, onShelf(2)),
        shelvingEntry(2, "read"),
        bookEntry(1, "null"),
      }) }
      status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.is_nil(status.status_id)
      assert.is_false(status.shelved)
    end)

    it("selects the requested book when the root query contains multiple books", function()
      response = { 200, page({
        bookEntry(2, "null"),
        bookEntry(1, onShelf(1)),
        shelvingEntry(1, "read"),
      }, [["getBookByLegacyId({\"legacyId\":\"2\"})":{"__ref":"Book:kca://book/2"},]]
        .. [["getBookByLegacyId({\"legacyId\":\"1\"})":{"__ref":"Book:kca://book/1"}]]) }
      local status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.are.equal(STATUS.FINISHED, status.status_id)
      assert.is_true(status.shelved)
    end)

    it("finds the requested cache in nested script data", function()
      local nested = shelvedPage("read")
        :gsub("<script>", [[<script id="__NEXT_DATA__">{"props":{"pageProps":{"apolloState":]])
        :gsub("</script>", "}}}</script>")
      response = { 200, page({ bookEntry(2, "null") },
        [["getBookByLegacyId({\"legacyId\":\"2\"})":{"__ref":"Book:kca://book/2"}]]) .. nested }
      local status, err = api:findUserBook("1")
      assert.is_nil(err)
      assert.are.equal(STATUS.FINISHED, status.status_id)
    end)

    it("returns an error for malformed script data even when null is present", function()
      response = { 200, UNSHELVED_PAGE:gsub("}</script>", "</script>") }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)

    it("returns an error when an HTTP 200 page has no readable shelf", function()
      response = { 200, UNREADABLE_PAGE }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)

    it("doesn't take the shelf of the next book when its own is missing", function()
      for _, next_book in ipairs({
        bookEntry(2, "null"),
        [["Book:kca://book/2":{"viewerShelving":null,"__typename":"Book","legacyId":2}]],
      }) do
        response = { 200, page({
          [["Book:kca://book/1":{"__typename":"Book","legacyId":1}]],
          next_book,
        }) }
        local status, err = api:findUserBook("1")
        assert.is_string(err)
        assert.are.same({}, status)
      end
    end)

    it("returns an error when the page's own book can't be found", function()
      response = { 200, [[<script>{]] .. bookEntry(1, "null") .. [[}</script>]] }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)

    it("returns an error when the shelving reference can't be resolved", function()
      response = { 200, page({ bookEntry(1, onShelf(1)) }) }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)

    it("doesn't take the shelf of a different shelving reference", function()
      response = { 200, page({
        bookEntry(1, onShelf(1)),
        shelvingEntry(2, "read"),
      }) }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)

    it("returns an error when the referenced shelving has no shelf", function()
      response = { 200, page({
        bookEntry(1, onShelf(1)),
        [["]] .. shelvingRef(1) .. [[":{"__typename":"Shelving"}]],
        shelvingEntry(2, "currently-reading"),
      }) }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)

    it("returns an error when the page can't be fetched", function()
      response = { 503, "" }
      local status, err = api:findUserBook("1")
      assert.is_string(err)
      assert.are.same({}, status)
    end)
  end)

  describe("Goodreads:linkBook", function()
    local provider

    before_each(function()
      local settings = GoodreadsSettings:new("/settings/goodreads.lua", ui, nil)
      provider = buildProvider(GoodreadsProvider, settings, goodreadsApi(settings))
    end)

    it("adds a book confirmed to be on no shelf to Currently Reading", function()
      assert.is_true(provider:linkBook({ book_id = "1", title = "Test Book" }))
      assert.are.same({ GOODREADS.STATUS.READING }, writes)
      assert.are.equal(GOODREADS.STATUS.READING, provider.state.book_status.status_id)
    end)

    it("keeps a recognized existing status", function()
      response = { 200, shelvedPage("read") }
      provider:linkBook({ book_id = "1", title = "Test Book" })
      assert.are.same({}, writes)
      assert.are.equal(GOODREADS.STATUS.FINISHED, provider.state.book_status.status_id)
    end)

    it("leaves a book on an unrecognized shelf where it is", function()
      response = { 200, shelvedPage("favorites") }
      provider:linkBook({ book_id = "1", title = "Test Book" })
      assert.are.same({}, writes)
      assert.are.equal(0, #shown)
    end)

    for _, case in ipairs({
      { "the page can't be fetched", { nil, "Network not connected" } },
      { "the page has no readable shelf", { 200, UNREADABLE_PAGE } },
    }) do
      it("links without changing the status when " .. case[1], function()
        response = case[2]
        assert.is_true(provider:linkBook({ book_id = "1", title = "Test Book" }))
        assert.are.same({}, writes)
        assert.are.equal("1", provider.settings:readBookSetting(FILE, "book_id"))
        assert.matches("couldn't check the book's status", shown[1].text, 1, true)
      end)
    end
  end)

  describe("Goodreads:pushProgress", function()
    local provider

    before_each(function()
      local settings = GoodreadsSettings:new("/settings/goodreads.lua", ui, nil)
      settings:updateBookSetting(FILE, { book_id = "1" })
      provider = buildProvider(GoodreadsProvider, settings, goodreadsApi(settings))
      provider.state.book_status = { id = "1", book_id = "1", status_id = GOODREADS.STATUS.READING }
      -- The progress write succeeded but reading the book page back didn't.
      provider.api.updateProgress = function() return {}, "Failed to read shelf from book page" end
    end)

    it("keeps the known status when the book page can't be read back", function()
      local result = provider:pushProgress(nil, 50, "percentage", FILE)
      assert.are.equal(GOODREADS.STATUS.READING, result.status_id)
      assert.are.same({}, writes)
    end)

    it("still marks a finished book as Read", function()
      local result = provider:pushProgress(nil, 100, "percentage", FILE)
      assert.are.same({ GOODREADS.STATUS.FINISHED }, writes)
      assert.are.equal(GOODREADS.STATUS.FINISHED, result.status_id)
    end)

    for _, case in ipairs({ { 100, "percentage" }, { 320, "pages" } }) do
      it("keeps the known status when the Read write can't be read back (" .. case[2] .. ")", function()
        provider.state.book_status.book_num_of_pages = 320
        provider.api.updateUserBook = function(_, _, status_id)
          table.insert(writes, status_id)
          return {}, "Failed to read shelf from book page"
        end
        local result = provider:pushProgress(nil, case[1], case[2], FILE)
        assert.are.same({ GOODREADS.STATUS.FINISHED }, writes)
        assert.are.equal(GOODREADS.STATUS.READING, result.status_id)
      end)
    end
  end)

  describe("Goodreads SyncEngine for an already-linked book", function()
    local engine, api

    before_each(function()
      NetworkMgr._wifi_on = true
      NetworkMgr._connected = true

      local settings = GoodreadsSettings:new("/settings/goodreads.lua", ui, nil)
      settings:updateBookSetting(FILE, { book_id = "1" })
      api = goodreadsApi(settings)
      local provider = buildProvider(GoodreadsProvider, settings, api)
      provider.wifi = AutoWifi:new { settings = settings, label = "Goodreads" }

      engine = SyncEngine:new {
        label = "Goodreads",
        constants = GOODREADS,
        highlight_menu_name = "hl_goodreads",
        api = api, user = provider.user, cache = provider.cache,
        wifi = provider.wifi, dialog_manager = {},
        provider = provider, settings = settings,
        plugin_settings = settings,
        ui = ui, state = provider.state,
      }
    end)

    it("adds a book confirmed to be on no shelf to Currently Reading", function()
      engine:startReadCache()
      UIManager:_runUntilIdle()

      assert.are.same({ GOODREADS.STATUS.READING }, writes)
      assert.is_true(engine.state.process_page_turns)
    end)

    it("leaves a book on an unrecognized shelf where it is", function()
      response = { 200, shelvedPage("favorites") }
      engine:startReadCache()
      UIManager:_runUntilIdle()

      assert.are.same({}, writes)
      assert.are.equal(1, api.requests)
      assert.is_true(engine.state.book_status.shelved)
      assert.is_true(engine.state.process_page_turns)
    end)

    for _, case in ipairs({
      { "the page can't be fetched", { 503, "" } },
      { "the page has no readable shelf", { 200, UNREADABLE_PAGE } },
    }) do
      it("retries without changing the status when " .. case[1], function()
        response = case[2]
        engine:startReadCache()
        UIManager:_runUntilIdle()

        assert.are.same({}, writes)
        assert.are.equal(6, api.requests)
        assert.is_nil(engine.state.process_page_turns)
      end)
    end

    it("names the shelf when warning that a book on an unrecognized shelf isn't syncing", function()
      local dialog
      engine.dialog_manager = { confirm = function(_, opts) dialog = opts end }
      engine.state.book_status = { id = "1", shelved = true, shelf = "read_later" }

      assert.is_true(engine:warnStatusMismatch(FILE))
      assert.matches('on the "read_later" shelf on Goodreads', dialog.text, 1, true)
      assert.is_nil(dialog.text:find("no status", 1, true))
    end)
  end)

  describe("Hardcover:linkBook", function()
    local provider, query_result, query_error

    before_each(function()
      query_result, query_error = nil, nil
      local settings = HardcoverSettings:new("/settings/hardcover.lua", ui, nil)
      local api = setmetatable({
        settings = settings,
        query = function() return query_result, query_error end,
        updateUserBook = recordWrite,
      }, { __index = HardcoverApi })
      provider = buildProvider(HardcoverProvider, settings, api)
    end)

    it("adds a book with no user book to Currently Reading", function()
      query_result = { user_books = {} }
      provider:linkBook({ book_id = 42, title = "Test Book" })
      assert.are.same({ STATUS.READING }, writes)
    end)

    it("keeps an existing user book's status", function()
      query_result = { user_books = { { id = 7, book_id = 42, status_id = STATUS.FINISHED } } }
      provider:linkBook({ book_id = 42, title = "Test Book" })
      assert.are.same({}, writes)
      assert.are.equal(STATUS.FINISHED, provider.state.book_status.status_id)
    end)

    it("links without changing the status when the lookup fails", function()
      query_error = { request_error = "timeout" }
      assert.is_true(provider:linkBook({ book_id = 42, title = "Test Book" }))
      assert.are.same({}, writes)
      assert.are.equal(42, provider.settings:readBookSetting(FILE, "book_id"))
      assert.matches("couldn't check the book's status", shown[1].text, 1, true)
    end)

    it("links without changing the status when the lookup isn't sent", function()
      -- HardcoverApi:query returns nothing at all while offline.
      provider:linkBook({ book_id = 42, title = "Test Book" })
      assert.are.same({}, writes)
    end)
  end)

  describe("StoryGraph:linkBook", function()
    local provider

    before_each(function()
      local settings = StoryGraphSettings:new("/settings/storygraph.lua", ui, nil)
      local api = setmetatable({
        settings = settings,
        request = function() return response[1], response[2] end,
        updateUserBook = recordWrite,
      }, { __index = StoryGraphApi })
      provider = buildProvider(StoryGraphProvider, settings, api)
    end)

    it("adds a book with no status to Currently Reading", function()
      response = { 200, "<html><body>No status here</body></html>" }
      provider:linkBook({ book_id = "abc", title = "Test Book" })
      assert.are.same({ STATUS.READING }, writes)
    end)

    it("keeps a recognized existing status", function()
      response = { 200, '<button class="read-status-label" type="button">read</button>' }
      provider:linkBook({ book_id = "abc", title = "Test Book" })
      assert.are.same({}, writes)
      assert.are.equal(STATUS.FINISHED, provider.state.book_status.status_id)
    end)

    it("links without changing the status when the lookup fails", function()
      response = { 503, "" }
      assert.is_true(provider:linkBook({ book_id = "abc", title = "Test Book" }))
      assert.are.same({}, writes)
      assert.are.equal("abc", provider.settings:readBookSetting(FILE, "book_id"))
      assert.matches("couldn't check the book's status", shown[1].text, 1, true)
    end)

    describe("when the user has a status on another edition", function()
      local edition_responses

      before_each(function()
        links = { {
          attributes = { href = "/books/other" },
          textonly = function() return "Currently reading another edition" end,
        } }
        edition_responses = { abc = { 200, "<html><body>No status here</body></html>" } }
        provider.api.request = function(_, url)
          local r = edition_responses[url:match("/books/([^/]+)$")]
          return r[1], r[2]
        end
      end)

      it("uses that edition's status", function()
        edition_responses.other = { 200, '<button class="read-status-label" type="button">currently reading</button>' }
        provider:linkBook({ book_id = "abc", title = "Test Book" })
        assert.are.same({}, writes)
        assert.are.equal(STATUS.READING, provider.state.book_status.status_id)
      end)

      it("links without changing the status when that edition can't be fetched", function()
        edition_responses.other = { 503, "" }
        local status, err = provider.api:findUserBook("abc")
        assert.is_string(err)
        assert.are.same({}, status)

        provider:linkBook({ book_id = "abc", title = "Test Book" })
        assert.are.same({}, writes)
        assert.matches("couldn't check the book's status", shown[1].text, 1, true)
      end)
    end)
  end)

  describe("Fable:linkBook", function()
    local provider

    before_each(function()
      local settings = FableSettings:new("/settings/fable.lua", ui, nil)
      local api = setmetatable({
        settings = settings,
        request = function() return response[1], response[2] end,
        updateUserBook = recordWrite,
      }, { __index = FableApi })
      provider = buildProvider(FableProvider, settings, api)
    end)

    it("adds a book with no status to Currently Reading", function()
      response = { 200, { response = {} } }
      provider:linkBook({ book_id = "abc", title = "Test Book", page_count = 300 })
      assert.are.same({ STATUS.READING }, writes)
    end)

    it("keeps an existing status", function()
      response = { 200, { response = { status = "finished" } } }
      provider:linkBook({ book_id = "abc", title = "Test Book", page_count = 300 })
      assert.are.same({}, writes)
      assert.are.equal(STATUS.FINISHED, provider.state.book_status.status_id)
    end)

    it("links without changing the status when the lookup fails", function()
      response = { 503 }
      assert.is_true(provider:linkBook({ book_id = "abc", title = "Test Book", page_count = 300 }))
      assert.are.same({}, writes)
      assert.are.equal("abc", provider.settings:readBookSetting(FILE, "book_id"))
      assert.matches("couldn't check the book's status", shown[1].text, 1, true)
    end)
  end)

  describe("Pagebound:linkBook", function()
    local provider

    before_each(function()
      local settings = PageboundSettings:new("/settings/pagebound.lua", ui, nil)
      local api = setmetatable({
        settings = settings,
        request = function() return response[1], response[2] end,
        updateUserBook = recordWrite,
      }, { __index = PageboundApi })
      provider = buildProvider(PageboundProvider, settings, api)
    end)

    it("adds a book that isn't in the library to Currently Reading", function()
      response = { 200, { book = { id = 9, title = "Test Book", page_count = 300 } } }
      provider:linkBook({ book_id = 9, book_uuid = "uuid-9", title = "Test Book" })
      assert.are.same({ STATUS.READING }, writes)
    end)

    it("links without changing the status when the lookup fails", function()
      response = { 503 }
      assert.is_true(provider:linkBook({ book_id = 9, book_uuid = "uuid-9", title = "Test Book" }))
      assert.are.same({}, writes)
      assert.are.equal("9", provider.settings:readBookSetting(FILE, "book_id"))
      assert.matches("couldn't check the book's status", shown[1].text, 1, true)
    end)
  end)
end)
