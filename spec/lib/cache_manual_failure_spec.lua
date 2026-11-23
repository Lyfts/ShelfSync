require("spec.support.koreader_mocks")
local Cache = require("shelfsync/lib/common/cache")
local STATUS = require("shelfsync/lib/common/constants/status").STATUS

describe("Manual status and removal failures", function()
  local cache
  before_each(function()
    cache = Cache:new {
      settings = {
        readBookSetting = function() return "book" end,
        readBookSettings = function() return { book_id = "book" } end,
        providerEnabled = function() return true end,
        pending_updates = {
          get = function() return nil end,
          clearFinishedElsewhere = function() end,
        },
      },
      provider = { findUserBookFor = function() error("provider failed") end },
      api = {}, state = {},
    }
    cache.serializeUpdate = function(_, callback) callback(nil) end
    cache.updateBookStatus = function() error("provider failed") end
  end)

  it("reports a status exception to the caller", function()
    local result
    cache:queueBookStatus("/book.epub", STATUS.FINISHED, function(ok) result = ok end)
    assert.is_false(result)
  end)

  it("reports a removal exception to the caller", function()
    local result
    cache:queueBookRemoval("/book.epub", function(ok) result = ok end)
    assert.is_false(result)
  end)
end)
