require("spec.support.koreader_mocks")
local dkjson = require("dkjson")
local json = {
  encode = dkjson.encode,
  util = { null = dkjson.null, InitArray = function(value) return value end },
}
json.decode = setmetatable({ simple = {} }, {
  __call = function(_, text)
    local value, _, err = dkjson.decode(text, 1, dkjson.null)
    if err then error(err) end
    return value
  end,
})
package.loaded["json"] = json
local Goodreads = require("shelfsync/lib/goodreads/api")
local Hardcover = require("shelfsync/lib/hardcover/api")
local Fable = require("shelfsync/lib/fable/api")
local Pagebound = require("shelfsync/lib/pagebound/api")

describe("Review requests", function()
  local saved_util
  before_each(function()
    saved_util = json.util
    json.util = { null = {}, InitArray = function(t) return t end }
  end)
  after_each(function() json.util = saved_util end)
  it("submits Goodreads review text through the current Next.js action", function()
    local action_id = string.rep("b", 40)
    local book_id = "kca://book/123"
    local edit_url = "https://www.goodreads.com/review/edit/123"
    local flight = json.encode({
      bookId = book_id,
      readingSessions = {},
      userFormattedText = "Original review",
      initialPrivateNotes = "A & B",
      initialPostToBlog = true,
      initialAddToUpdateFeed = false,
      spoilerStatus = true,
      isAlreadyOwned = true,
    })
    local editor_html = '<script src="/_next/static/chunks/app/review/edit/%5Bid%5D/page-test.js"></script>'
      .. "<script>self.__next_f.push([1," .. json.encode(flight) .. "])</script>"
    local calls, submitted = {}, nil
    local api = setmetatable({
      settings = { debugLog = function() end, debugWarn = function() end },
      refreshSession = function() return nil end,
      request = function(_, url, verb, body, headers)
        calls[#calls + 1] = { url, verb }
        if verb == "GET" and url == edit_url then return 200, editor_html end
        if verb == "GET" and url:match("page%-test%.js$") then
          return 200, '(0,N.createServerReference)("' .. action_id
            .. '",N.callServer,void 0,N.findSourceMapURL,"submitReviewFormAction")'
        end
        if verb == "POST" and url == edit_url then
          assert.equals(action_id, headers["Next-Action"])
          submitted = json.decode(body)[1]
          return 200, '{"legacyId":"123","errors":"$Q1"}\n1:[]'
        end
        error("Unexpected Goodreads request: " .. tostring(verb) .. " " .. tostring(url))
      end,
    }, { __index = Goodreads })

    assert.is_true(api:setReviewText(123, "New text"))
    assert.equals(3, #calls)
    assert.equals("POST", calls[3][2])
    assert.equals("New text", submitted.reviewText)
    assert.same({}, submitted.readingSessions)
    assert.equals("$0:0:readingSessions", submitted.initialReadingSessions)
    assert.equals("A & B", submitted.privateNotes)
    assert.is_true(submitted.postToBlog)
    assert.is_false(submitted.addToUpdateFeed)
    assert.is_true(submitted.spoilerStatus)
    assert.is_true(submitted.isOwnedEdition)
  end)

  it("does not submit review text when the Next.js editor state is unreadable", function()
    local api = setmetatable({
      settings = { debugLog = function() end, debugWarn = function() end },
      refreshSession = function() return nil end,
      request = function(_, _, method) assert.equals("GET", method); return 200, "Login required" end,
    }, { __index = Goodreads })
    local ok, err = api:setReviewText(123, "Review")
    assert.is_nil(ok)
    assert.matches("Could not read", err)
  end)

  it("preserves omitted Hardcover fields and accepts a null error", function()
    local api = setmetatable({ query = function(_, query, variables)
      assert.is_nil(variables.rating)
      assert.is_nil(query:find("rating: $rating", 1, true))
      assert.equals("Review", variables.review.document.children[1].children[1].text)
      return { update_user_book = { error = json.util.null, user_book = { id = 42 } } }
    end }, { __index = Hardcover })
    assert.same({ id = 42 }, api:updateReview(42, nil, "Review"))
  end)

  it("returns Hardcover mutation failures", function()
    local api = setmetatable({ query = function()
      return { update_user_book = { error = "Permission denied" } }
    end }, { __index = Hardcover })
    local ok, err = api:updateReview(42, 4, "Review")
    assert.is_nil(ok)
    assert.equals("Permission denied", err)
  end)

  it("creates a Fable review after a missing-review lookup and reports write failure", function()
    local api = setmetatable({
      getReview = function() return nil, 404 end,
      request = function(_, path, method, body)
        assert.equals("/api/books/123/reviews", path)
        assert.equals("POST", method)
        assert.equals("Review", body.review)
        return 500
      end,
    }, { __index = Fable })
    local ok, err = api:setReview(123, 4, "Review")
    assert.is_false(ok)
    assert.matches("HTTP 500", err)
  end)

  it("does not overwrite a Fable review when its lookup fails", function()
    local api = setmetatable({
      getReview = function() return nil, 401 end,
      request = function() error("must not write") end,
    }, { __index = Fable })
    local ok, err = api:setReview(123, 4, "Review")
    assert.is_false(ok)
    assert.matches("HTTP 401", err)
  end)

  it("submits Pagebound reviews to the native review endpoint with both book IDs", function()
    local request_body
    local api = setmetatable({
      request = function(_, path, method, body)
        assert.equals("/api/v1/reviews", path)
        assert.equals("POST", method)
        request_body = body
        return 201, { id = 789 }
      end,
    }, { __index = Pagebound })

    assert.is_true(api:setReview("123", "456", 4.5, "Pagebound review"))
    local review = request_body.review
    assert.equals(4.5, review.overall_rating)
    assert.equals(123, review.book_id)
    assert.equals(456, review.user_book_id)
    assert.equals("Pagebound review", review.review)
    assert.is_false(review.is_spoiler)
    assert.is_false(review.is_dnf)
    assert.same({}, review.emojis)
    assert.equals(json.util.null, review.quality_rating)
  end)

  it("sends a Pagebound text-only review without a rating", function()
    local request_body
    local api = setmetatable({
      request = function(_, _, _, body)
        request_body = body
        return 200, {}
      end,
    }, { __index = Pagebound })

    assert.is_true(api:setReview(123, 456, nil, "Text only"))
    assert.equals(json.util.null, request_body.review.overall_rating)
    assert.equals("Text only", request_body.review.review)
  end)
end)
