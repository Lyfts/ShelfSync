require("spec.support.koreader_mocks")
local SyncEngine = require("shelfsync/lib/common/sync_engine")

describe("Shared manual progress", function()
  local engine, remote_pages, by_pages, sent

  before_each(function()
    remote_pages, by_pages, sent = 400, true, nil
    engine = SyncEngine:new {
      label = "Hardcover",
      ui = { document = { file = "/books/current.epub", getPageCount = function() return 200 end } },
      settings = { pages = function() return remote_pages end, syncByRemotePages = function() return by_pages end },
      provider = {},
      page_mapper = { getRemotePagePercent = function(_, page, total, remote)
        return page / total, remote and math.floor(page / total * remote + 0.5)
      end },
    }
    engine.state.book_status = { status_id = "reading" }
    engine._handlePageUpdate = function(_, file, value, immediate, callback, kind)
      sent = { file = file, value = value, immediate = immediate, kind = kind }
      callback(true)
    end
  end)

  it("maps the selected local page to an edition page", function()
    local result
    engine:updateProgressAtLocalPage(function(ok) result = ok end, 50)
    assert.is_true(result)
    assert.same({ file = "/books/current.epub", value = 100, immediate = true, kind = "pages" }, sent)
  end)

  it("uses a percentage when edition-page tracking is off", function()
    by_pages = false
    engine:updateProgressAtLocalPage(function() end, 50)
    assert.equals(25, sent.value)
    assert.equals("percentage", sent.kind)
  end)

  it("rejects missing required edition page counts", function()
    remote_pages = nil
    engine.provider.requires_remote_page_count = true
    local result, reason
    engine:updateProgressAtLocalPage(function(ok, err) result, reason = ok, err end, 50)
    assert.is_nil(result)
    assert.matches("page count", reason)
    assert.is_nil(sent)
  end)

  it("refreshes an unknown remote status before sending a manual update", function()
    engine.state.book_status = {}
    local refreshes = 0
    engine.cache = { cacheUserBook = function()
      refreshes = refreshes + 1
      engine.state.book_status = { status_id = "reading" }
    end }
    engine.wifi = { withWifi = function(_, fn) fn(false, nil) end }

    local result
    engine:updateProgressAtLocalPage(function(ok) result = ok end, 50)

    assert.equals(1, refreshes)
    assert.is_true(result)
    assert.equals(100, sent.value)
  end)

  it("reports a failed status refresh instead of sending blind", function()
    engine.state.book_status = {}
    engine.cache = { cacheUserBook = function() return "offline" end }
    engine.wifi = { withWifi = function(_, fn) fn(false, nil) end }

    local result, reason
    engine:updateProgressAtLocalPage(function(ok, err) result, reason = ok, err end, 50)

    assert.is_nil(result)
    assert.matches("Could not fetch book information", reason)
    assert.is_nil(sent)
  end)
end)
