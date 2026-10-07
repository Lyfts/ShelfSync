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

describe("Goodreads finished dates", function()
  local saved_json_util
  local book_id = "kca://book/286957"
  local edit_url = "https://www.goodreads.com/review/edit/286957"
  local action_id = string.rep("a", 40)

  before_each(function()
    saved_json_util = json.util
    json.util = { null = {}, InitArray = function(value) return value end }
  end)

  after_each(function()
    json.util = saved_json_util
  end)

  local function date(year, month, day)
    return { __typename = "NullableDate", year = year, month = month, day = day }
  end

  local function editor_html(sessions, fields)
    fields = fields or {}
    local flight = json.encode({
      bookId = book_id,
      readingSessions = sessions,
      initialPrivateNotes = fields.private_notes or "",
      userFormattedText = fields.review_text or "",
      initialPostToBlog = fields.post_to_blog or false,
      initialAddToUpdateFeed = fields.add_to_feed ~= false,
      spoilerStatus = fields.spoiler_status or false,
      isAlreadyOwned = fields.is_owned_edition or false,
    })
    return '<html><script src="/_next/static/chunks/app/review/edit/%5Bid%5D/page-test.js"></script>'
      .. "<script>self.__next_f.push([1," .. json.encode(flight) .. "])</script></html>"
  end

  local function make_api(initial_sessions, opts)
    opts = opts or {}
    local calls = { get_editor = 0, get_chunk = 0, post = 0 }
    local submitted
    local submitted_body
    local saved_sessions
    local api = setmetatable({
      settings = { debugLog = function() end, debugWarn = function() end },
      refreshSession = function() return nil end,
      request = function(_, url, method, body, headers)
        if method == "GET" and url == edit_url then
          calls.get_editor = calls.get_editor + 1
          if calls.get_editor == 1 then
            return 200, editor_html(initial_sessions, opts.fields)
          end
          return 200, editor_html(opts.verify_sessions or saved_sessions or initial_sessions, opts.fields)
        elseif method == "GET" and url:match("page%-test%.js$") then
          calls.get_chunk = calls.get_chunk + 1
          return 200, '(0,N.createServerReference)("' .. action_id
            .. '",N.callServer,void 0,N.findSourceMapURL,"submitReviewFormAction")'
        elseif method == "POST" and url == edit_url then
          calls.post = calls.post + 1
          assert.equals(action_id, headers["Next-Action"])
          submitted_body = body
          submitted = json.decode(body)[1]
          if opts.persist_posted_sessions ~= false then
            saved_sessions = submitted.readingSessions
          end
          return 200, '{"legacyId":"286957","errors":"$Q1"}\n1:[]'
        end
        error("Unexpected Goodreads request: " .. tostring(method) .. " " .. tostring(url))
      end,
    }, { __index = Goodreads })
    return api, calls, function() return submitted, submitted_body end
  end

  it("skips a date already present in the current reading sessions", function()
    local finished_at = os.time({ year = 2026, month = 10, day = 6, hour = 12 })
    local sessions = {
      {
        __typename = "ReadingSession",
        id = "session-current",
        bookId = book_id,
        state = "COMPLETED",
        startedDate = date(2026, 10, 5),
        endedDate = date(2026, 10, 6),
      },
    }
    local api, calls = make_api(sessions)

    assert.is_true(api:setDateFinished("286957", finished_at))
    assert.equals(1, calls.get_editor)
    assert.equals(0, calls.get_chunk)
    assert.equals(0, calls.post)
  end)

  it("uses today for an immediate finish with no queued timestamp", function()
    local today = os.date("*t")
    local api, _, submitted = make_api({})

    assert.is_true(api:setDateFinished("286957"))
    local payload, body = submitted()
    assert.same({}, payload.initialReadingSessions)
    assert.same(date(today.year, today.month, today.day), payload.readingSessions[1].endedDate)
    assert.matches('"initialReadingSessions":%[%]', body)
  end)

  it("adds the queued finish date when existing sessions are from an older read", function()
    local finished_at = os.time({ year = 2026, month = 10, day = 3, hour = 12 })
    local old_session = {
      __typename = "ReadingSession",
      id = "session-old",
      bookId = book_id,
      state = "COMPLETED",
      startedDate = date(2026, 8, 1),
      endedDate = date(2026, 8, 20),
    }
    local api, calls, submitted = make_api({ old_session })

    assert.is_true(api:setDateFinished("286957", finished_at))
    local payload = submitted()
    assert.equals(1, calls.post)
    assert.equals(2, #payload.readingSessions)
    assert.same(old_session, payload.readingSessions[1])
    local new_session = payload.readingSessions[2]
    assert.matches("^new%-", new_session.id)
    assert.equals("COMPLETED", new_session.state)
    assert.same(date(2026, 10, 3), new_session.startedDate)
    assert.same(date(2026, 10, 3), new_session.endedDate)
    assert.same({ old_session }, payload.initialReadingSessions)
  end)

  it("finishes the active session and preserves review settings and other sessions", function()
    local finished_at = os.time({ year = 2026, month = 10, day = 6, hour = 12 })
    local old_session = {
      __typename = "ReadingSession",
      id = "session-old",
      bookId = book_id,
      state = "COMPLETED",
      startedDate = date(2026, 7, 1),
      endedDate = date(2026, 7, 20),
    }
    local active_session = {
      __typename = "ReadingSession",
      id = "session-active",
      bookId = book_id,
      state = "READING",
      startedDate = date(2026, 10, 3),
      endedDate = json.util.null,
    }
    local fields = {
      review_text = "Keep this review",
      private_notes = "Keep these private notes",
      post_to_blog = true,
      add_to_feed = false,
      spoiler_status = true,
      is_owned_edition = true,
    }
    local api, calls, submitted = make_api({ old_session, active_session }, { fields = fields })

    assert.is_true(api:setDateFinished("286957", finished_at))
    local payload = submitted()
    assert.equals(2, #payload.readingSessions)
    assert.same(old_session, payload.readingSessions[1])
    assert.equals("session-active", payload.readingSessions[2].id)
    assert.same(date(2026, 10, 6), payload.readingSessions[2].endedDate)
    assert.same({ old_session, active_session }, payload.initialReadingSessions)
    assert.equals("Keep this review", payload.reviewText)
    assert.equals("Keep these private notes", payload.privateNotes)
    assert.is_true(payload.postToBlog)
    assert.is_false(payload.addToUpdateFeed)
    assert.is_true(payload.spoilerStatus)
    assert.is_true(payload.isOwnedEdition)
    assert.equals(2, calls.get_editor)
    assert.equals(1, calls.get_chunk)
    assert.equals(1, calls.post)
  end)

  it("reports failure if Goodreads does not return the requested date", function()
    local finished_at = os.time({ year = 2026, month = 10, day = 6, hour = 12 })
    local sessions = {
      {
        __typename = "ReadingSession",
        id = "session-old",
        bookId = book_id,
        state = "COMPLETED",
        startedDate = date(2026, 8, 1),
        endedDate = date(2026, 8, 20),
      },
    }
    local api, _, submitted = make_api(sessions, { persist_posted_sessions = false })

    local ok, err = api:setDateFinished("286957", finished_at)
    assert.is_nil(ok)
    assert.matches("did not confirm", err)
    assert.is_truthy(submitted())
  end)

  it("stops with a clear error when the current editor state cannot be read", function()
    local calls = {}
    local api = setmetatable({
      settings = { debugLog = function() end, debugWarn = function() end },
      refreshSession = function() return nil end,
      request = function(_, url, method)
        calls[#calls + 1] = { url, method }
        return 200, "Editor state unavailable"
      end,
    }, { __index = Goodreads })

    local ok, err = api:setDateFinished("286957", 1791288000)
    assert.is_nil(ok)
    assert.matches("review editor state", err)
    assert.same({ { edit_url, "GET" } }, calls)
  end)
end)
