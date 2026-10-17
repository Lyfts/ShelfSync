-- Goodreads takes quarter-star ratings (since October 2026) through the
-- same /review/rate request as whole stars.

require("spec.support.koreader_mocks")

local GoodreadsApi = require("shelfsync/lib/goodreads/api")

describe("GoodreadsApi:setRating", function()
  local api, urls

  before_each(function()
    urls = {}
    api = setmetatable({
      settings = { debugLog = function() end, debugWarn = function() end },
      refreshSession = function() return "csrf" end,
      request = function(_, url)
        table.insert(urls, url)
        return 204, ""
      end,
    }, { __index = GoodreadsApi })
  end)

  it("sends quarter stars as they are", function()
    for _, rating in ipairs({ 0.25, 3.5, 4.75, 5 }) do
      assert.is_true(api:setRating("36475366", rating))
    end
    local sent = {}
    for _, url in ipairs(urls) do table.insert(sent, url:match("[?&]rating=([^&]+)")) end
    assert.same({ "0.25", "3.5", "4.75", "5" }, sent)
  end)

  it("rounds anything finer down to a quarter star, and refuses no rating", function()
    assert.is_true(api:setRating("36475366", 4.6))
    assert.equals("4.5", urls[1]:match("[?&]rating=([^&]+)"))
    assert.is_nil(api:setRating("36475366", 0.1))
    assert.equals(1, #urls)
  end)
end)
