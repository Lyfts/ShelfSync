local Book = require("shelfsync/lib/common/book")

describe("Book", function()
  describe("parseIdentifiers", function()
    it("parses 10 character strings as isbn10", function()
      local identifiers = "asin:1234567890"
      local expected = {
        isbn_10 = "1234567890"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses 13 character strings as isbn13", function()
      local identifiers = "asin 13:1234567890123"
      local expected = {
        isbn_13 = "1234567890123"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses hardcover book and editions", function()
      local identifiers = [[
HARDCOVER:the-hobbit
HARDCOVER-EDITION:16193290
]]

      local expected = {
        book_slug = "16193290"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses hardcover-slug", function()
      local identifiers = "HARDCOVER-SLUG:1984"
      local expected = {
        book_slug = "1984"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("prioritizes hardcover editions over isbn", function()
      local identifiers = [[
HARDCOVER:1234567890
HARDCOVER-EDITION:1234567890123
]]

      local expected = {
        book_slug = "1234567890123"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses a goodreads id", function()
      local identifiers = "GOODREADS:256017244"
      local expected = {
        goodreads_id = "256017244"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses a goodreads id alongside an isbn", function()
      local identifiers = [[
GOODREADS:256017244
ISBN:1234567890123
]]

      local expected = {
        goodreads_id = "256017244",
        isbn_13 = "1234567890123"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses a storygraph slug into its own field, not book_slug", function()
      local identifiers = "STORYGRAPH:the-hobbit"
      local expected = {
        storygraph_slug = "the-hobbit"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses a storygraph edition into its own field, not book_slug", function()
      local identifiers = "STORYGRAPH-EDITION:16193290"
      local expected = {
        storygraph_slug = "16193290"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("keeps hardcover and storygraph identifiers from colliding when both are present", function()
      local identifiers = [[
HARDCOVER:the-hobbit
STORYGRAPH:a-different-slug
]]

      local expected = {
        book_slug = "the-hobbit",
        storygraph_slug = "a-different-slug"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)
  end)
end)
