local mocks = require("spec.support.koreader_mocks")
local Api = require("shelfsync/lib/goodreads/api")
local http = require("socket.http")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")

describe("GoodreadsApi:request redirect credentials", function()
  local api, requests, responses, settings_data, sent_cookies

  before_each(function()
    mocks.reset()
    requests = {}
    responses = {}
    sent_cookies = {}
    settings_data = {
      session_cookie = "goodreads-session=secret",
      cookie_refresh_url = "http://127.0.0.1:5080",
      cookie_refresh_token = "refresh-token",
    }
    api = setmetatable({
      settings = {
        readSetting = function(_, key) return settings_data[key] end,
        updateSetting = function(_, key, value) settings_data[key] = value end,
      },
    }, { __index = Api })

    stub(NetworkManager, "isConnected", function() return true end)
    stub(Trapper, "dismissableRunInSubprocess", function(_, fn) return true, fn() end)
    stub(socketutil, "set_timeout", function() end)
    stub(socketutil, "reset_timeout", function() end)
    stub(socketutil, "table_sink", function(chunks)
      return function(chunk)
        if chunk then chunks[#chunks + 1] = chunk end
        return 1
      end
    end)
    stub(http, "request", function(request)
      requests[#requests + 1] = request
      sent_cookies[#requests] = request.headers.Cookie
      local response = responses[#requests]
      assert.is_truthy(response, "unexpected HTTP request " .. tostring(request.url))
      if response.body then request.sink(response.body) end
      return 1, response.code, response.headers or {}
    end)
  end)

  after_each(function()
    mock.revert(NetworkManager)
    mock.revert(Trapper)
    mock.revert(socketutil)
    mock.revert(http)
  end)

  it("disables LuaSocket redirects and refuses a cross-host redirect", function()
    responses[1] = { code = 302, headers = { location = "https://example.com/collect" } }

    local code = api:request("https://www.goodreads.com/search?q=book")

    assert.equals(302, code)
    assert.equals(1, #requests)
    assert.is_false(requests[1].redirect)
    assert.equals("goodreads-session=secret", requests[1].headers.Cookie)
  end)

  it("refuses redirects to plain HTTP, including 308 and 200 Location responses", function()
    for _, response in ipairs({
      { code = 302, location = "http://www.goodreads.com/collect" },
      { code = 308, location = "https://example.com/collect" },
      { code = 200, location = "https://example.com/collect" },
    }) do
      requests = {}
      responses = { { code = response.code, headers = { location = response.location } } }

      local code = api:request("https://www.goodreads.com/search?q=book")

      assert.equals(response.code, code)
      assert.equals(1, #requests)
      assert.is_false(requests[1].redirect)
    end
  end)

  it("keeps following redirects within the Goodreads HTTPS origin", function()
    responses[1] = { code = 302, headers = { location = "/book/show/123" } }
    responses[2] = { code = 200, body = "book page", headers = {} }

    local code, body, headers = api:request("https://www.goodreads.com/search?q=book")

    assert.equals(200, code)
    assert.equals("book page", body)
    assert.equals("https://www.goodreads.com/book/show/123", headers["x-final-url"])
    assert.equals(2, #requests)
    assert.is_false(requests[1].redirect)
    assert.is_false(requests[2].redirect)
    assert.equals("goodreads-session=secret", requests[2].headers.Cookie)
  end)

  it("replays a Goodreads session self-redirect with its newly issued cookie", function()
    local url = "https://www.goodreads.com/user/show/123"
    responses[1] = {
      code = 302,
      headers = {
        location = url,
        ["set-cookie"] = "_session_id2=fresh; path=/",
      },
    }
    responses[2] = { code = 200, body = "profile", headers = {} }

    local code, body = api:request(url)

    assert.equals(200, code)
    assert.equals("profile", body)
    assert.equals(2, #requests)
    assert.equals(url, requests[1].url)
    assert.equals(url, requests[2].url)
    assert.equals("goodreads-session=secret", sent_cookies[1])
    assert.matches("_session_id2=fresh", sent_cookies[2], 1, true)
  end)

  it("follows Goodreads' same-origin 200 Location search response", function()
    responses[1] = {
      code = 200,
      headers = { location = "https://www.goodreads.com/book/show/123" },
    }
    responses[2] = { code = 200, body = "book page", headers = {} }

    local code, body, headers = api:request("https://www.goodreads.com/search?q=isbn")

    assert.equals(200, code)
    assert.equals("book page", body)
    assert.equals(2, #requests)
    assert.equals("https://www.goodreads.com/book/show/123", headers["x-final-url"])
    assert.is_false(requests[1].redirect)
    assert.is_false(requests[2].redirect)
  end)

  it("does not send or refresh cookies for an off-origin WAF response", function()
    responses[1] = { code = 403, headers = { ["x-amzn-waf-action"] = "challenge" } }

    local code = api:request("https://example.com/collect", "GET", nil, { cookie = "custom-secret" })

    assert.equals(403, code)
    assert.equals(1, #requests)
    assert.is_nil(requests[1].headers.Cookie)
    assert.is_nil(requests[1].headers.cookie)
  end)

  it("does not bootstrap a cookie from the refresher for an off-origin URL", function()
    settings_data.session_cookie = nil
    responses[1] = { code = 200, body = "external page", headers = {} }

    local code = api:request("https://example.com/collect")

    assert.equals(200, code)
    assert.equals(1, #requests)
    assert.equals("https://example.com/collect", requests[1].url)
    assert.is_nil(requests[1].headers.Cookie)
  end)
end)
