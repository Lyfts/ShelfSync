local mocks = require("spec.support.koreader_mocks")
local Api = require("shelfsync/lib/goodreads/api")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")

describe("GoodreadsApi session cookies", function()
  local api, requests, responses, settings_data, sent_cookies

  before_each(function()
    mocks.reset()
    requests = {}
    responses = {}
    sent_cookies = {}
    settings_data = { session_cookie = "goodreads-session=secret" }
    api = setmetatable({
      settings = {
        readSetting = function(_, key) return settings_data[key] end,
        updateSetting = function(_, key, value) settings_data[key] = value end,
        debugLog = function() end,
        debugWarn = function() end,
      },
    }, { __index = Api })

    stub(NetworkManager, "isConnected", function() return true end)
    stub(Trapper, "dismissableRunInSubprocess", function(_, fn) return true, fn() end)
    stub(socketutil, "set_timeout", function() end)
    stub(socketutil, "reset_timeout", function() end)
    ltn12.source = ltn12.source or {}
    stub(ltn12.source, "string", function(s) return s end)
    stub(socketutil, "table_sink", function(chunks)
      return function(chunk)
        if chunk then chunks[#chunks + 1] = chunk end
        return 1
      end
    end)
    stub(http, "request", function(request)
      requests[#requests + 1] = request
      sent_cookies[#requests] = request.headers and request.headers.Cookie
      local response = responses[#requests]
      assert.is_truthy(response, "unexpected HTTP request " .. tostring(request.url))
      if response.during then response.during() end
      if response.body then request.sink(response.body) end
      return 1, response.code, response.headers or {}
    end)
  end)

  after_each(function()
    mock.revert(NetworkManager)
    mock.revert(Trapper)
    mock.revert(socketutil)
    mock.revert(ltn12.source)
    mock.revert(http)
  end)

  local function set_session(code)
    return { code = code or 200, body = "page", headers = { ["set-cookie"] = "_session_id2=fresh; path=/; HttpOnly" } }
  end

  it("sends cookies Goodreads set with the requests that follow", function()
    responses[1] = set_session()
    responses[2] = { code = 200, body = "page", headers = {} }
    responses[3] = { code = 200, body = "page", headers = {} }

    local _, _, headers = api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/review/list")
    api:request("https://www.goodreads.com/book/show/1")

    assert.equals("goodreads-session=secret", sent_cookies[1])
    assert.equals("goodreads-session=secret; _session_id2=fresh", sent_cookies[2])
    assert.equals("goodreads-session=secret; _session_id2=fresh", sent_cookies[3])
    assert.is_nil(headers["x-session-cookie"])
    assert.equals("goodreads-session=secret", settings_data.session_cookie)
  end)

  it("keeps cookies set on every hop of a redirect", function()
    responses[1] = { code = 302, headers = { location = "/", ["set-cookie"] = "first=1; path=/" } }
    responses[2] = { code = 200, body = "page", headers = { ["set-cookie"] = "second=2; path=/" } }
    responses[3] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/review/list")
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=secret; first=1; second=2", sent_cookies[3])
  end)

  it("drops them when the saved cookie changes", function()
    responses[1] = set_session()
    responses[2] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    settings_data.session_cookie = "goodreads-session=new"
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=new", sent_cookies[2])
  end)

  it("drops them when the saved cookie is removed, even if it's restored later", function()
    responses[1] = set_session()
    responses[2] = { code = 200, body = "page", headers = {} }
    responses[3] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    settings_data.session_cookie = nil
    api:request("https://www.goodreads.com/")
    settings_data.session_cookie = "goodreads-session=secret"
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=secret", sent_cookies[3])
  end)

  it("doesn't keep cookies from a request sent before the saved cookie changed", function()
    responses[1] = set_session()
    responses[1].during = function() settings_data.session_cookie = "goodreads-session=new" end
    responses[2] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=new", sent_cookies[2])
  end)

  it("adds cookies from a slower response to those kept since it went out", function()
    responses[1] = { code = 200, body = "page", headers = { ["set-cookie"] = "_session_id2=old; path=/" } }
    responses[2] = { code = 200, body = "page", headers = { ["set-cookie"] = "analytics=1; path=/" } }
    -- Another request, sent and back before the first is.
    responses[2].during = function() api:request("https://www.goodreads.com/") end
    responses[3] = set_session()
    responses[4] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=secret; _session_id2=old", sent_cookies[3])
    assert.equals("goodreads-session=secret; _session_id2=fresh; analytics=1", sent_cookies[4])
  end)

  it("keeps cookies for the saved cookie a retry went out with", function()
    Trapper.dismissableRunInSubprocess:revert()
    local attempts = 0
    stub(Trapper, "dismissableRunInSubprocess", function(_, fn)
      attempts = attempts + 1
      if attempts == 1 then
        settings_data.session_cookie = "goodreads-session=new"
        return false
      end
      return true, fn()
    end)
    responses[1] = set_session()
    responses[2] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=new", sent_cookies[1])
    assert.equals("goodreads-session=new; _session_id2=fresh", sent_cookies[2])
  end)

  it("doesn't keep cookies from a request out while the cookie-refresher replaced the cookie", function()
    settings_data.cookie_refresh_url = "http://127.0.0.1:5080"
    settings_data.cookie_refresh_token = "refresh-token"
    responses[1] = { code = 200, body = "page", headers = { ["set-cookie"] = "aws-waf-token=stale; path=/" } }
    responses[2] = { code = 200, body = "page", headers = { ["set-cookie"] = "_session_id2=late; path=/" } }
    -- Another request, refreshed to the same cookie, before the first is back.
    responses[2].during = function() api:request("https://www.goodreads.com/") end
    responses[3] = { code = 202, body = "", headers = { ["x-amzn-waf-action"] = "challenge" } }
    responses[4] = { code = 200, body = "goodreads-session=secret" }
    responses[5] = { code = 200, body = "page", headers = {} }
    responses[6] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("http://127.0.0.1:5080/refresh", requests[4].url)
    assert.equals("goodreads-session=secret", sent_cookies[5])
    assert.equals("goodreads-session=secret", sent_cookies[6])
  end)

  it("drops them when the cookie-refresher replaces the cookie, even with the same one", function()
    settings_data.cookie_refresh_url = "http://127.0.0.1:5080"
    settings_data.cookie_refresh_token = "refresh-token"
    responses[1] = { code = 200, body = "page", headers = { ["set-cookie"] = "aws-waf-token=stale; path=/" } }
    responses[2] = { code = 202, body = "", headers = { ["x-amzn-waf-action"] = "challenge" } }
    responses[3] = { code = 200, body = "goodreads-session=secret" }
    responses[4] = { code = 200, body = "page", headers = {} }
    responses[5] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    local code = api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals(200, code)
    assert.equals("http://127.0.0.1:5080/refresh", requests[3].url)
    assert.equals("goodreads-session=secret; aws-waf-token=stale", sent_cookies[2])
    assert.equals("goodreads-session=secret", sent_cookies[4])
    assert.equals("goodreads-session=secret", sent_cookies[5])
  end)

  it("doesn't keep cookies set before the cookie-refresher replaced the cookie", function()
    settings_data.cookie_refresh_url = "http://127.0.0.1:5080"
    settings_data.cookie_refresh_token = "refresh-token"
    responses[1] = {
      code = 202,
      body = "",
      headers = { ["x-amzn-waf-action"] = "challenge", ["set-cookie"] = "aws-waf-token=challenged; path=/" },
    }
    responses[2] = { code = 200, body = "goodreads-session=secret; aws-waf-token=solved" }
    responses[3] = { code = 200, body = "page", headers = {} }
    responses[4] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("http://127.0.0.1:5080/refresh", requests[2].url)
    assert.equals("goodreads-session=secret; aws-waf-token=solved", sent_cookies[3])
    assert.equals("goodreads-session=secret; aws-waf-token=solved", sent_cookies[4])
  end)

  it("drops them when Goodreads asks to sign in again", function()
    stub(api, "notifyAuthFailure")
    responses[1] = set_session()
    responses[2] = { code = 401, body = "", headers = {} }
    responses[3] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    local _, _, _, err = api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("Unauthorized", err)
    assert.equals("goodreads-session=secret", sent_cookies[3])
  end)

  it("keeps cookies for a new saved cookie when a request sent before it gets a 401", function()
    stub(api, "notifyAuthFailure")
    responses[1] = { code = 401, body = "", headers = {} }
    responses[1].during = function()
      settings_data.session_cookie = "goodreads-session=new"
      api:request("https://www.goodreads.com/")
    end
    responses[2] = set_session()
    responses[3] = { code = 200, body = "page", headers = {} }

    local _, _, _, err = api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("Unauthorized", err)
    assert.equals("goodreads-session=new; _session_id2=fresh", sent_cookies[3])
  end)

  it("keeps the cookie-refresher's replacement when a request sent before it gets a 401", function()
    stub(api, "notifyAuthFailure")
    settings_data.cookie_refresh_url = "http://127.0.0.1:5080"
    settings_data.cookie_refresh_token = "refresh-token"
    responses[1] = { code = 200, body = "page", headers = { ["set-cookie"] = "_session_id2=old; path=/" } }
    responses[2] = { code = 401, body = "", headers = {} }
    -- Another request, refreshed to the same cookie, before the first is back.
    responses[2].during = function() api:request("https://www.goodreads.com/") end
    responses[3] = { code = 202, body = "", headers = { ["x-amzn-waf-action"] = "challenge" } }
    responses[4] = { code = 200, body = "goodreads-session=secret" }
    responses[5] = set_session()
    responses[6] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    local _, _, _, err = api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("Unauthorized", err)
    assert.equals("http://127.0.0.1:5080/refresh", requests[4].url)
    assert.equals("goodreads-session=secret; _session_id2=fresh", sent_cookies[6])
  end)

  it("doesn't keep cookies set by another site", function()
    responses[1] = { code = 200, body = "page", headers = { ["set-cookie"] = "tracker=1; path=/" } }
    responses[2] = { code = 200, body = "page", headers = {} }

    api:request("https://example.com/collect")
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=secret", sent_cookies[2])
  end)

  it("doesn't take a response header of the same name as kept cookies", function()
    responses[1] = { code = 200, body = "page", headers = { ["x-session-cookie"] = "planted=1" } }
    responses[2] = { code = 200, body = "page", headers = {} }

    api:request("https://www.goodreads.com/")
    api:request("https://www.goodreads.com/")

    assert.equals("goodreads-session=secret", sent_cookies[2])
  end)

  it("sends a shelf change with the session its CSRF token came from", function()
    responses[1] = {
      code = 200,
      body = '<meta name="csrf-token" content="token-for-fresh" />',
      headers = { ["set-cookie"] = "_session_id2=fresh; path=/; HttpOnly" },
    }
    responses[2] = { code = 404, body = "Page not found", headers = {} }

    api:updateUserBook("286957", 2)

    assert.equals(2, #requests)
    assert.equals("https://www.goodreads.com/shelf/add_to_shelf", requests[2].url)
    assert.equals("token-for-fresh", requests[2].headers["X-CSRF-Token"])
    assert.equals("goodreads-session=secret; _session_id2=fresh", sent_cookies[2])
  end)
end)
