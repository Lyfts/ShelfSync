require("spec.support.koreader_mocks")
local Goodreads = require("shelfsync/lib/goodreads/api")
local Hardcover = require("shelfsync/lib/hardcover/api")
local Fable = require("shelfsync/lib/fable/api")
local Pagebound = require("shelfsync/lib/pagebound/api")
local json = require("json")

describe("Review requests", function()
  local saved_util
  before_each(function()
    saved_util = json.util
    json.util = { null = {}, InitArray = function(t) return t end }
  end)
  after_each(function() json.util = saved_util end)
  for _, method in ipairs({ "post", "put" }) do
    it("uses the Goodreads form action and " .. method .. " method", function()
      local calls = {}
      local api = setmetatable({
        settings = { debugLog = function() end, debugWarn = function() end },
        refreshSession = function() return "csrf" end,
        request = function(_, url, verb, body)
          calls[#calls + 1] = { url, verb, body }
          if verb == "GET" then
            return 200, '<form action="/review/987">'
              .. (method == "put" and '<input name="_method" value="put">' or '')
              .. '<textarea name="review[review]">old</textarea>'
              .. '<textarea name="review[notes]">A &amp; B</textarea></form>'
          end
          return 302, ""
        end,
      }, { __index = Goodreads })
      assert.is_true(api:setReviewText(123, "New text"))
      assert.equals("https://www.goodreads.com/review/987", calls[2][1])
      assert.equals(method == "put" and "put" or nil, calls[2][3]._method)
      assert.equals("New text", calls[2][3]["review[review]"])
      assert.equals("A & B", calls[2][3]["review[notes]"])
    end)
  end

  it("does not guess a Goodreads update URL when the form is missing", function()
    local api = setmetatable({
      settings = { debugLog = function() end, debugWarn = function() end },
      refreshSession = function() return "csrf" end,
      request = function(_, _, method) assert.equals("GET", method); return 200, "Login required" end,
    }, { __index = Goodreads })
    local ok, err = api:setReviewText(123, "Review")
    assert.is_nil(ok)
    assert.matches("Could not locate", err)
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
