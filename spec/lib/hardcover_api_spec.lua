-- Regression test for a crash when manually linking a Hardcover book: the
-- `editions` GraphQL query returns `publisher` as an object (`{ name }`),
-- but normalizedEdition passed it straight through as `result.publisher`.
-- search_dialog.lua then does `table.insert(details, book.publisher)`
-- assuming a string, and `table.concat`ing that details list crashes with
-- "invalid value (table) at index N" as soon as a matched book has a
-- publisher -- which is exactly the flow findBookByIdentifiers -> isbn
-- lookup -> normalizedEdition -> showLinkBookDialog hits.

require("spec.support.koreader_mocks")

local HardcoverApi = require("shelfsync/lib/hardcover/api")

describe("HardcoverApi:normalizedEdition", function()
  it("normalizes publisher to a string, not the raw GraphQL object", function()
    local edition = {
      id = 999,
      book = { book_id = 1, title = "Test Book" },
      edition_format = nil,
      reading_format_id = nil,
      cached_image = nil,
      publisher = { name = "Test Publisher" },
      language = { code2 = "en", language = "English" },
      release_date = "2020-05-01",
      pages = 300,
      users_count = 10,
    }

    local result = HardcoverApi:normalizedEdition(edition)

    assert.are.equal("Test Publisher", result.publisher)
    assert.is_string(result.publisher)
  end)

  it("leaves publisher nil when the edition has none", function()
    local edition = {
      id = 999,
      book = { book_id = 1, title = "Test Book" },
    }

    local result = HardcoverApi:normalizedEdition(edition)

    assert.is_nil(result.publisher)
  end)
end)
