local mocks = require("spec.support.koreader_mocks")
local GoodreadsApi = require("shelfsync/lib/goodreads/api")

describe("GoodreadsApi:findBooks", function()
  local api, auth_failures

  before_each(function()
    mocks.reset()
    auth_failures = 0
    api = setmetatable({
      request = function() end,
      notifyAuthFailure = function() auth_failures = auth_failures + 1 end,
    }, { __index = GoodreadsApi })
  end)

  it("finds books when Goodreads changes its result-link markup", function()
    local html = [[
      <section>
        <a class="book-title" href="/book/show/123-sample-book"><span>Sample <em>Book</em> &amp; More</span></a>
        <span data-testid="name">Jane Doe</span>
        <a href="/book/show/123-another-link">Duplicate</a>
        <a href="/book/show/456-second-book">Second Book</a>
      </section>
    ]]
    api.request = function(_, url)
      assert.matches("/search%?q=Sample%+Book", url)
      return 200, html, { ["x-final-url"] = "https://www.goodreads.com/search?q=Sample+Book" }
    end

    local books, err = api:findBooks("Sample Book")

    assert.is_nil(err)
    assert.equals(2, #books)
    assert.equals("123", books[1].book_id)
    assert.equals("Sample Book & More", books[1].title)
    assert.equals("Jane Doe", books[1].contributions[1].author.name)
    assert.equals("456", books[2].book_id)
  end)

  it("preserves request failures for the shared manual-link dialog", function()
    api.request = function() return nil, "Network not connected" end

    local books, err = api:findBooks("A title")

    assert.same({}, books)
    assert.equals("Network not connected", err)
  end)

  it("reports Goodreads bot challenges instead of returning an empty search", function()
    api.request = function()
      return 403, "challenge", { ["x-amzn-waf-action"] = "challenge" }
    end

    local books, err = api:findBooks("A title")

    assert.same({}, books)
    assert.matches("WAF", err)
  end)

  it("notifies the account flow when search is redirected to sign-in", function()
    api.request = function()
      return 200, "sign in page", { ["x-final-url"] = "https://www.goodreads.com/user/sign_in" }
    end

    local books, err = api:findBooks("A title")

    assert.same({}, books)
    assert.equals("Unauthorized", err)
    assert.equals(1, auth_failures)
  end)
end)
