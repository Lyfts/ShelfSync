-- Covers which privacy_setting_id Hardcover writes are sent with when the
-- caller doesn't pass one. A failed or empty `me` lookup must never make a
-- new user book or journal entry Public, and a status change on an existing
-- user book (insert_user_book also updates existing records) must keep that
-- record's own privacy rather than resetting it to the account default.

require("spec.support.koreader_mocks")

package.loaded["json"] = {
  encode = function() return "{}" end,
  decode = function() end,
  util = { InitArray = function(t) return t end, null = {} },
}

local HardcoverApi = require("shelfsync/lib/hardcover/api")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")

-- A HardcoverApi whose query() answers from `responses` instead of the
-- network, recording what was looked up and what was written.
local function makeApi(responses)
  local calls = { me = 0, lookups = {} }
  local api = setmetatable({
    query = function(_, query, variables)
      if query:find("account_privacy_setting_id", 1, true) then
        calls.me = calls.me + 1
        return responses.me
      elseif query:find("insert_user_book", 1, true) then
        calls.user_book = variables.object
        return { insert_user_book = { user_book = { id = 1 } } }
      elseif query:find("insert_reading_journal", 1, true) then
        calls.journal = variables.object
        return { insert_reading_journal = { id = 1 } }
      elseif query:find("user_books(where", 1, true) then
        table.insert(calls.lookups, variables)
        return responses.user_books, responses.user_books_error
      end
    end,
  }, { __index = HardcoverApi })
  return api, calls
end

local function me(account)
  return { me = { account } }
end

describe("HardcoverApi:me", function()
  it("returns an empty table when the response has no user", function()
    local api = makeApi({ me = { me = {} } })

    assert.are.same({}, api:me())
  end)
end)

describe("HardcoverApi:updateUserBook privacy", function()
  it("doesn't write anything when the account lookup fails", function()
    local api, calls = makeApi({ me = nil })

    local result, err = api:updateUserBook(10, HARDCOVER.STATUS.READING)

    assert.is_nil(result)
    assert.is_truthy(err)
    assert.is_nil(calls.user_book)
  end)

  it("doesn't write anything when the account lookup returns no user", function()
    local api, calls = makeApi({ me = { me = {} } })

    local result, err = api:updateUserBook(10, HARDCOVER.STATUS.READING)

    assert.is_nil(result)
    assert.is_truthy(err)
    assert.is_nil(calls.user_book)
  end)

  describe("for a new user book", function()
    it("uses Private when the account has no default privacy", function()
      local api, calls = makeApi({
        me = me({ id = 7 }),
        user_books = { user_books = {} },
      })

      api:updateUserBook(10, HARDCOVER.STATUS.READING)

      assert.are.equal(HARDCOVER.PRIVACY.PRIVATE, calls.user_book.privacy_setting_id)
    end)

    it("uses the account's default privacy when known", function()
      local api, calls = makeApi({
        me = me({ id = 7, account_privacy_setting_id = HARDCOVER.PRIVACY.FOLLOWS }),
        user_books = { user_books = {} },
      })

      api:updateUserBook(10, HARDCOVER.STATUS.READING)

      assert.are.same({ { id = 10, userId = 7 } }, calls.lookups)
      assert.are.equal(HARDCOVER.PRIVACY.FOLLOWS, calls.user_book.privacy_setting_id)
    end)
  end)

  describe("for an existing user book", function()
    it("keeps the record's own privacy instead of the account default", function()
      local api, calls = makeApi({
        me = me({ id = 7, account_privacy_setting_id = HARDCOVER.PRIVACY.PUBLIC }),
        user_books = { user_books = { { id = 1, book_id = 10, privacy_setting_id = HARDCOVER.PRIVACY.PRIVATE } } },
      })

      api:updateUserBook(10, HARDCOVER.STATUS.FINISHED)

      assert.are.equal(HARDCOVER.PRIVACY.PRIVATE, calls.user_book.privacy_setting_id)
    end)

    it("keeps the record's own privacy when the account has no default privacy", function()
      local api, calls = makeApi({
        me = me({ id = 7 }),
        user_books = { user_books = { { id = 1, book_id = 10, privacy_setting_id = HARDCOVER.PRIVACY.FOLLOWS } } },
      })

      api:updateUserBook(10, HARDCOVER.STATUS.FINISHED)

      assert.are.equal(HARDCOVER.PRIVACY.FOLLOWS, calls.user_book.privacy_setting_id)
    end)

    it("doesn't write anything when the record's privacy can't be read", function()
      local lookup_error = { request_error = "timeout" }
      local api, calls = makeApi({
        me = me({ id = 7, account_privacy_setting_id = HARDCOVER.PRIVACY.PUBLIC }),
        user_books = nil,
        user_books_error = lookup_error,
      })

      local result, err = api:updateUserBook(10, HARDCOVER.STATUS.FINISHED)

      assert.is_nil(result)
      assert.are.equal(lookup_error, err)
      assert.is_nil(calls.user_book)
    end)

    it("doesn't write anything when the lookup returns no data or error", function()
      local api, calls = makeApi({
        me = me({ id = 7, account_privacy_setting_id = HARDCOVER.PRIVACY.PUBLIC }),
      })

      local result, err = api:updateUserBook(10, HARDCOVER.STATUS.FINISHED)

      assert.is_nil(result)
      assert.is_truthy(err)
      assert.is_nil(calls.user_book)
    end)

    it("doesn't replace missing record privacy with the account default", function()
      local api, calls = makeApi({
        me = me({ id = 7, account_privacy_setting_id = HARDCOVER.PRIVACY.PUBLIC }),
        user_books = { user_books = { { id = 1, book_id = 10 } } },
      })

      local result, err = api:updateUserBook(10, HARDCOVER.STATUS.FINISHED)

      assert.is_nil(result)
      assert.is_truthy(err)
      assert.is_nil(calls.user_book)
    end)
  end)

  it("sends an explicitly passed privacy without looking anything up", function()
    local api, calls = makeApi({})

    api:updateUserBook(10, HARDCOVER.STATUS.READING, HARDCOVER.PRIVACY.FOLLOWS, 99)

    assert.are.equal(0, calls.me)
    assert.are.equal(0, #calls.lookups)
    assert.are.equal(HARDCOVER.PRIVACY.FOLLOWS, calls.user_book.privacy_setting_id)
    assert.are.equal(99, calls.user_book.edition_id)
  end)
end)

describe("HardcoverApi:createJournalEntry privacy", function()
  local entry = { book_id = 10, text = "A note" }

  it("uses Private when the account lookup fails", function()
    local api, calls = makeApi({ me = nil })

    assert.is_truthy(api:createJournalEntry(entry))
    assert.are.equal(HARDCOVER.PRIVACY.PRIVATE, calls.journal.privacy_setting_id)
  end)

  it("uses Private when the account lookup returns no user", function()
    local api, calls = makeApi({ me = { me = {} } })

    assert.is_truthy(api:createJournalEntry(entry))
    assert.are.equal(HARDCOVER.PRIVACY.PRIVATE, calls.journal.privacy_setting_id)
  end)

  it("uses the account's default privacy when known", function()
    local api, calls = makeApi({ me = me({ id = 7, account_privacy_setting_id = HARDCOVER.PRIVACY.FOLLOWS }) })

    assert.is_truthy(api:createJournalEntry(entry))
    assert.are.equal(HARDCOVER.PRIVACY.FOLLOWS, calls.journal.privacy_setting_id)
  end)
end)
