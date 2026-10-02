require("spec.support.koreader_mocks")

local Goodreads = require("shelfsync/lib/goodreads/provider")
local Hardcover = require("shelfsync/lib/hardcover/provider")
local Fable = require("shelfsync/lib/fable/provider")
local Pagebound = require("shelfsync/lib/pagebound/provider")
local StoryGraph = require("shelfsync/lib/storygraph/provider")

describe("Review rating precision", function()
  -- Include values below one star, ties, and the upper boundary.
  local cases = {
    { 0.25, 0, 0, 0 }, { 0.75, 0, 0.5, 0.5 },
    { 1, 1, 1, 1 }, { 3.5, 3, 3.5, 3.5 },
    { 4.25, 4, 4, 4 }, { 4.75, 4, 4.5, 4.5 }, { 5, 5, 5, 5 },
  }
  for _, case in ipairs(cases) do
    it("rounds " .. case[1] .. " down only where required", function()
      local sent = {}
      local context = {
        settings = { readBookSetting = function() return 42 end },
        state = { book_status = { id = 42, user_book_id = 99 } },
        api = {
          setRating = function(_, _, rating) sent.goodreads = rating; return {} end,
          setReviewText = function() return {} end,
          updateReview = function(_, _, rating) sent.hardcover = rating; return {} end,
          setReview = function(_, book_id, first, second, third)
            if third ~= nil then
              sent.pagebound = { book_id, first, second, third }
            else
              sent.fable = first
            end
            return true
          end,
          saveReview = function(_, _, review) sent.storygraph = review.stars; return {} end,
        },
      }
      assert.is_true(Goodreads.submitReview(context, "book.epub", case[1], "Review"))
      assert.is_true(Hardcover.submitReview(context, "book.epub", case[1], "Review"))
      assert.is_true(Fable.submitReview(context, "book.epub", case[1], "Review"))
      assert.is_true(Pagebound.submitReview(context, "book.epub", case[1], "Review"))
      assert.is_true(StoryGraph.submitReview(context, "book.epub", case[1], "Review"))
      assert.same({
        goodreads = case[2], hardcover = case[3], fable = case[1],
        pagebound = { 42, 99, case[4], "Review" }, storygraph = case[1],
      }, sent)
    end)
  end

  it("refreshes Pagebound status before using the reading-list review ID", function()
    local sent
    local context
    context = {
      settings = { readBookSetting = function() return 42 end },
      state = { book_status = { user_book_id = 98 } },
      cache = { cacheUserBook = function()
        context.state.book_status = { user_book_id = 99 }
      end },
      api = { setReview = function(_, ...)
        sent = { ... }
        return true
      end },
    }

    assert.is_true(Pagebound.submitReview(context, "book.epub", 3.75, "Review"))
    assert.same({ 42, 99, 3.5, "Review" }, sent)
  end)
end)
