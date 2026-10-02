local mocks = require("spec.support.koreader_mocks")
package.loaded.htmlparser = package.loaded.htmlparser or { parse = function() end }
local Api = require("shelfsync/lib/storygraph/api")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")

describe("StoryGraph email/password login", function()
  local api, settings, requests, responses
  before_each(function()
    mocks.reset()
    settings = { session_cookie = "existing-session", remember_token = "existing-remember" }
    api = setmetatable({
      settings = {
        readSetting = function(_, key) return settings[key] end,
        updateSetting = function(_, key, value) settings[key] = value end,
      },
      last_csrf = "stale-csrf",
      last_auth_warning = 123,
    }, { __index = Api })
    requests = {}
    responses = {
      { 200, '<input name="authenticity_token" value="fresh+csrf==">',
        { ["set-cookie"] = "_storygraph_session=guest; path=/" } },
      { 303, "", { location = "https://app.thestorygraph.com/",
        ["set-cookie"] = "remember_user_token=new-remember; expires=Fri, 07 Sep 2046 11:31:55 GMT; path=/, _storygraph_session=new-session; path=/" } },
    }
    stub(NetworkManager, "isConnected", function() return true end)
    stub(Trapper, "dismissableRunInSubprocess", function(_, fn) return true, fn() end)
    stub(socketutil, "set_timeout", function() end)
    stub(socketutil, "reset_timeout", function() end)
    stub(socketutil, "table_sink", function(t)
      return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
    end)
    ltn12.source = ltn12.source or {}
    stub(ltn12.source, "string", function(s)
      return function() local chunk = s; s = nil; return chunk end
    end)
    stub(http, "request", function(req)
      requests[#requests + 1] = req
      req.body = req.source and req.source() or nil
      local response = responses[#requests]
      req.sink(response[2])
      return 1, response[1], response[3]
    end)
  end)
  after_each(function() mock.revert(NetworkManager); mock.revert(Trapper)
    mock.revert(socketutil); mock.revert(ltn12.source); mock.revert(http)
  end)

  it("posts encoded credentials with fresh CSRF and guest cookies, then saves both cookies", function()
    assert.is_true(api:login(" reader+test@example.com ", "p&=+ secret"))
    assert.is_nil(requests[1].headers.Cookie)
    assert.is_false(requests[2].redirect)
    assert.equals("_storygraph_session=guest", requests[2].headers.Cookie)
    assert.equals("fresh+csrf==", requests[2].headers["X-CSRF-Token"])
    assert.equals("authenticity_token=fresh%2Bcsrf%3D%3D&user%5Bemail%5D=reader%2Btest%40example.com&user%5Bpassword%5D=p%26%3D%2B+secret&user%5Bremember_me%5D=1", requests[2].body)
    assert.same({ session_cookie = "new-session", remember_token = "new-remember" }, settings)
    assert.is_nil(api.last_csrf)
    assert.is_nil(api.last_auth_warning)
    assert.is_nil(table.concat(mocks.LOG, "\n"):find("secret", 1, true))
  end)

  it("preserves existing cookies when credentials are rejected", function()
    responses[2] = { 422, "Invalid credentials", {} }
    local ok, err = api:login("reader@example.com", "wrong-password")
    assert.is_nil(ok)
    assert.matches("Check your email and password", err, 1, true)
    assert.equals("existing-session", settings.session_cookie)
    assert.equals("existing-remember", settings.remember_token)
  end)

  it("reports Cloudflare challenges without persisting guest cookies", function()
    responses[2] = { 403, "Just a moment", { ["cf-mitigated"] = "challenge" } }
    local ok, err = api:login("reader@example.com", "password")
    assert.is_nil(ok)
    assert.matches("import browser cookies", err, 1, true)
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("uses Android WebView headers with distinct navigation and submit metadata", function()
    assert.is_true(api:login("reader@example.com", "password"))
    local navigation, submit = requests[1].headers, requests[2].headers
    assert.matches("Turbo Native Android", navigation["User-Agent"], 1, true)
    assert.equals(navigation["User-Agent"], submit["User-Agent"])
    assert.equals('"Android"', navigation["Sec-Ch-Ua-Platform"])
    assert.equals("?1", navigation["Sec-Ch-Ua-Mobile"])
    assert.equals("com.thestorygraph.thestorygraph", submit["X-Requested-With"])
    assert.equals("navigate", navigation["Sec-Fetch-Mode"])
    assert.equals("document", navigation["Sec-Fetch-Dest"])
    assert.equals("none", navigation["Sec-Fetch-Site"])
    assert.is_nil(navigation.Origin)
    assert.is_nil(navigation.Referer)
    assert.equals("cors", submit["Sec-Fetch-Mode"])
    assert.equals("empty", submit["Sec-Fetch-Dest"])
    assert.equals("same-origin", submit["Sec-Fetch-Site"])
    assert.is_nil(submit["Sec-Fetch-User"])
    assert.equals("https://app.thestorygraph.com", submit.Origin)
    assert.equals("https://app.thestorygraph.com/users/sign_in", submit.Referer)
    assert.matches("text/vnd.turbo-stream.html", submit.Accept, 1, true)
  end)

  it("identifies a page-load challenge and never submits credentials", function()
    responses[1] = { 403, "Challenge", { ["cf-mitigated"] = "challenge" } }
    local ok, err = api:login("reader@example.com", "password")
    assert.is_nil(ok)
    assert.matches("Cloudflare challenged login page load (GET) (HTTP 403)", err, 1, true)
    assert.equals(1, #requests)
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("distinguishes a plain forbidden submit from a Cloudflare challenge", function()
    responses[2] = { 403, "Forbidden", {} }
    local ok, err = api:login("reader@example.com", "password")
    assert.is_nil(ok)
    assert.matches("StoryGraph blocked login submission (POST) (HTTP 403)", err, 1, true)
    assert.is_nil(err:find("Cloudflare", 1, true))
  end)

  it("recognizes challenge headers before treating HTTP 200 as rejected credentials", function()
    responses[2] = { 200, "Challenge", { ["cf-mitigated"] = "challenge" } }
    local ok, err = api:login("reader@example.com", "password")
    assert.is_nil(ok)
    assert.matches("Cloudflare challenged login submission (POST) (HTTP 200)", err, 1, true)
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("logs login stages without credentials or session material", function()
    assert.is_true(api:login("reader@example.com", "private-password"))
    local logs = table.concat(mocks.LOG, "\n")
    assert.matches("Login GET /users/sign_in: HTTP 200", logs, 1, true)
    assert.matches("Login POST /users/sign_in: HTTP 303", logs, 1, true)
    for _, secret in ipairs({ "reader@example.com", "private-password", "fresh+csrf", "guest", "new-session", "new-remember" }) do
      assert.is_nil(logs:find(secret, 1, true))
    end
  end)

  it("does not reuse a stale CSRF token when the form is missing", function()
    responses[1][2] = "Unexpected page"
    assert.is_nil(api:login("reader@example.com", "password"))
    assert.equals(1, #requests)
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("requires authentication cookies even for a successful redirect", function()
    responses[2][3]["set-cookie"] = "_storygraph_session=guest; path=/"
    assert.is_nil(api:login("reader@example.com", "password"))
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("does not follow unexpected redirects or send credentials to another host", function()
    responses[2][3].location = "https://example.com/"
    assert.is_nil(api:login("reader@example.com", "password"))
    assert.equals(2, #requests)
    assert.is_false(requests[2].redirect)
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("does not make requests with empty credentials", function()
    assert.is_nil(api:login("  ", "password"))
    assert.is_nil(api:login("reader@example.com", ""))
    assert.equals(0, #requests)
  end)

  it("handles separate Set-Cookie headers", function()
    responses[2][3]["set-cookie"] = {
      "remember_user_token=new-remember; path=/",
      "_storygraph_session=new-session; path=/",
    }
    assert.is_true(api:login("reader@example.com", "password"))
    assert.equals("new-remember", settings.remember_token)
    assert.equals("new-session", settings.session_cookie)
  end)

  it("preserves cookies when the network request fails", function()
    http.request:revert()
    stub(http, "request", function() return nil, "timeout" end)
    local ok, err = api:login("reader@example.com", "password")
    assert.is_nil(ok)
    assert.matches("unavailable", err, 1, true)
    assert.equals("existing-session", settings.session_cookie)
  end)

  it("preserves cookies when login is cancelled", function()
    Trapper.dismissableRunInSubprocess:revert()
    stub(Trapper, "dismissableRunInSubprocess", function() return false end)
    assert.is_nil(api:login("reader@example.com", "password"))
    assert.equals("existing-session", settings.session_cookie)
    assert.equals(0, #requests)
  end)

  it("does not log bodies in ordinary POST requests", function()
    responses[1] = { 200, "OK", {} }
    api:request("https://app.thestorygraph.com/test", "POST", { note = "private-note" })
    assert.is_nil(table.concat(mocks.LOG, "\n"):find("private-note", 1, true))
    assert.is_nil(table.concat(mocks.LOG, "\n"):find("POST Body", 1, true))
  end)
end)
