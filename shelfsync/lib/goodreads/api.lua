-- Goodreads has no official public API, so this mirrors StoryGraph's
-- approach of replaying a real browser session against the classic (Rails)
-- pages, avoiding the modern Next.js/GraphQL surface entirely (it's gated
-- behind an AWS WAF bot-challenge on writes, and reads no real benefit from
-- it either). Two quirks specific to Goodreads, relative to StoryGraph:
--
-- 1. Goodreads accounts are linked through Amazon, so a valid session is a
--    bundle of ~13 cookies across goodreads.com and Amazon's own domains,
--    not a couple of named values. Rather than trying to parse/merge that
--    bundle, the whole raw `Cookie` header is stored and replayed verbatim
--    as one opaque blob (SETTING.GOODREADS.SESSION_COOKIE), with no attempt to track
--    Set-Cookie refreshes -- confirmed via HAR captures that write endpoints
--    only ever refresh `_session_id2`, and there's no evidence that matters
--    for auth validity.
-- 2. The book page (/book/show/{id}) and search page are server-rendered
--    Next.js/Apollo, not classic Rails forms, so there's no HTML form to
--    scrape a CSRF token from directly -- but the plain homepage (`/`) still
--    is classic Rails, and conveniently also exposes the viewer's legacy
--    numeric user id in a nav link, so one GET of `/` covers both `me()`
--    and CSRF-priming for a write.
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local config = (config_ok and shelfsync_config.goodreads) or {}
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local SETTING = require("shelfsync/lib/common/constants/settings")

local base_url = "https://www.goodreads.com"

local GoodreadsApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
}

-- Private helper to build headers with cookies
local function get_headers(self, custom_headers)
  local cookie = ""

  if self.settings then
    cookie = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE)
  end
  if not cookie or cookie == "" then cookie = config.cookie or "" end

  if cookie == "" then
    logger.warn("Goodreads: No session cookie found!")
  else
    logger.info("Goodreads: Using session cookie (length: " .. #cookie .. ")")
  end

  -- Defaults model a plain browser navigation (page load via address bar /
  -- link click), which is what every GET in this file is. Real browsers
  -- never send Origin on those, and omitting Referer/Sec-Fetch-*/
  -- Upgrade-Insecure-Requests -- confirmed via direct testing -- makes
  -- goodreads.com treat the request as suspicious and get stuck in an
  -- infinite self-redirect loop instead of ever serving the page. Write
  -- endpoints are real XHR calls, so they override these with their own
  -- Origin/Sec-Fetch-Mode: cors/Sec-Fetch-Dest: empty via custom_headers.
  local headers = {
    ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64; rv:154.0) Gecko/20100101 Firefox/154.0",
    ["Cookie"] = cookie,
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Referer"] = base_url .. "/",
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "navigate",
    ["Sec-Fetch-Dest"] = "document",
    ["Sec-Fetch-User"] = "?1",
    ["Upgrade-Insecure-Requests"] = "1",
    ["DNT"] = "1",
  }
  if custom_headers then
    for k, v in pairs(custom_headers) do
      headers[k] = v
    end
  end
  return headers
end

-- Mirrors get_headers()'s cookie resolution (setting, then legacy config
-- fallback) so callers can check for a usable credential without triggering
-- a network request or the "no session cookie" warning log.
function GoodreadsApi:hasCredential()
  local cookie = ""
  if self.settings then
    cookie = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE)
  end
  if not cookie or cookie == "" then cookie = config.cookie or "" end
  return cookie ~= ""
end

-- Helper to decode HTML entities
local function decode_entities(str)
  local entities = {
    ["&amp;"] = "&",
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&quot;"] = "\"",
    ["&apos;"] = "'",
    ["&#39;"] = "'",
    ["&rsquo;"] = "'",
    ["&lsquo;"] = "'",
    ["&ldquo;"] = "\"",
    ["&rdquo;"] = "\"",
    ["&ndash;"] = "-",
    ["&mdash;"] = "--",
  }
  return str:gsub("(&%w+;)", entities)
    :gsub("(&#x(%x+);)", function(_, hex) return string.char(tonumber(hex, 16) or 63) end)
    :gsub("(&#(%d+);)", function(_, dec) return string.char(tonumber(dec) or 63) end)
end

-- URL encoding helper
local function urlencode(str)
  if str then
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
      return ("%%%02X"):format(string.byte(c))
    end)
    str = str:gsub(" ", "+")
  end
  return str
end

-- Talks to the local cookie-refresher (see the separate
-- goodreads-cookie-refresher repo) -- shared by the two escape hatches
-- below, which only differ in HTTP method and endpoint. Best-effort
-- throughout: any failure here (not configured, refresher unreachable,
-- still logged out) just falls through to the caller's existing fallback.
local function fetch_from_refresher(url, method, auth_token, timeout)
  local sink = {}
  socketutil:set_timeout(timeout, timeout)
  local ok, code = http.request {
    url = url,
    method = method,
    headers = (auth_token and auth_token ~= "") and { ["X-Auth-Token"] = auth_token } or nil,
    sink = socketutil.table_sink(sink),
  }
  socketutil:reset_timeout()
  if ok and code == 200 then
    local cookie = table.concat(sink):gsub("^%s+", ""):gsub("%s+$", "")
    if cookie ~= "" then return cookie, code end
  end
  return nil, code
end

-- Turns a cookie-refresher failure's HTTP status into an actionable log
-- hint -- 401 (auth token mismatch) and "no cookie captured yet" used to
-- both just say "still logged out?", which sent past debugging in circles
-- cross-referencing docker logs to tell them apart.
local function refresher_failure_hint(code)
  if code == 401 then
    return "check Cookie Auto-Refresh Token matches REFRESHER_AUTH_TOKEN in the refresher's .env"
  end
  return "still logged out? see its noVNC view"
end

-- Escape hatch for the WAF-challenge dead end below: hits the refresher's
-- /refresh endpoint to force a freshly browser-solved cookie.
local function fetch_refreshed_cookie(refresh_url, auth_token, timeout)
  return fetch_from_refresher(refresh_url, "POST", auth_token, timeout)
end

-- Escape hatch for a never-configured cookie (fresh install, or
-- shelfsync_config.lua just never filled in): hits the refresher's /cookie
-- endpoint, which returns whatever it already has cached from a prior
-- noVNC login instead of forcing a new browser round-trip -- cheaper than
-- /refresh for something that would otherwise run on every request until a
-- cookie is actually found.
local function fetch_cached_cookie(cookie_url, auth_token, timeout)
  return fetch_from_refresher(cookie_url, "GET", auth_token, timeout)
end

local COOKIE_SKIP_ATTRS = {
  path = true, domain = true, expires = true, ["max-age"] = true,
  samesite = true, secure = true, httponly = true, version = true,
}

-- Goodreads' Rails session bootstrap issues a Set-Cookie for a fresh
-- _session_id2/srb_10 pair alongside a same-URL redirect, and won't proceed
-- past it until the client presents that exact cookie back -- confirmed via
-- curl: replaying the redirect without also resending the newly issued
-- cookies makes the same redirect repeat forever, always reissuing the same
-- Set-Cookie. LuaSocket comma-folds repeated Set-Cookie headers together,
-- and Expires values also contain commas, so this walks name=value pairs
-- directly (skipping known non-cookie attribute keys) instead of trying to
-- split into whole Set-Cookie statements first.
local function merge_set_cookie(cookie_header, set_cookie_value)
  if not set_cookie_value or set_cookie_value == "" then return cookie_header end

  local jar = {}
  local order = {}
  for k, v in (cookie_header or ""):gmatch("([%w_%-%.]+)=([^;]*)") do
    if not jar[k] then table.insert(order, k) end
    jar[k] = v
  end

  for k, v in set_cookie_value:gmatch("([%w_%-%.]+)=([^;,]*)") do
    if not COOKIE_SKIP_ATTRS[k:lower()] then
      if not jar[k] then table.insert(order, k) end
      jar[k] = v
    end
  end

  local parts = {}
  for _, k in ipairs(order) do
    table.insert(parts, k .. "=" .. jar[k])
  end
  return table.concat(parts, "; ")
end

-- Every /book/show/{id} page carries a <script type="application/ld+json">
-- block with a clean schema.org/Book object -- confirmed against a real
-- page as a far more reliable source for title/author/cover than either the
-- sparse OG tags (no author) or dereferencing the Next.js Apollo cache. Key
-- order is server-templated and stable, so each field is anchored to the
-- literal key that follows it in Goodreads' own output rather than
-- attempting a general JSON parse.
local function parse_ldjson_book(html)
  local block = html:match('<script type="application/ld%+json">(.-)</script>')
  if not block then return nil end

  local title = block:match('"name":"(.-)","image"')
  local image = block:match('"image":"(.-)","bookFormat"')
  local author = block:match('"author":%[{"@type":"Person","name":"(.-)"')

  if not title then return nil end

  return {
    title = decode_entities(title),
    image = image,
    author = author and decode_entities(author) or "Unknown Author",
  }
end

-- Helper to extract authenticity token from HTML. Only the classic homepage
-- carries this meta tag -- the book/search pages don't -- so this is always
-- called against a homepage fetch (see refreshSession below).
function GoodreadsApi:extract_csrf(html)
  if not html then return self.last_csrf end

  local csrf = html:match('<meta%s+[^>]*name=["\']csrf%-token["\']%s+[^>]*content=["\']([^"\']+)["\']')
            or html:match('<meta%s+[^>]*content=["\']([^"\']+)["\']%s+[^>]*name=["\']csrf%-token["\']')

  if csrf then
    self.last_csrf = csrf
  end

  return csrf or self.last_csrf
end

function GoodreadsApi:request(url, method, data, custom_headers)
  if not NetworkManager:isConnected() or not self.enabled then
    if self.settings then
      self.settings:debugWarn("Goodreads: request() aborted before sending - NetworkManager connected="
        .. tostring(NetworkManager:isConnected()) .. " enabled=" .. tostring(self.enabled) .. " url=" .. url)
    end
    return nil, "Network not connected"
  end

  local subprocess_fn = function()
    local maxtime = 15
    local timeout = 10

    local body = nil
    if data then
      if type(data) == "table" then
        local parts = {}
        for k, v in pairs(data) do
          table.insert(parts, urlencode(k) .. "=" .. urlencode(tostring(v)))
        end
        body = table.concat(parts, "&")
      else
        body = data
      end
    end

    local headers = get_headers(self, custom_headers)
    local refreshed_cookie -- surfaced to the parent via a pseudo-header below

    -- No cookie configured at all yet (fresh install, or shelfsync_config.lua
    -- never filled in) -- try the local cookie-refresher's cached cookie
    -- before ever making a request, instead of failing until the user
    -- manually pastes one in.
    if not headers["Cookie"] or headers["Cookie"] == "" then
      local refresh_base = self.settings and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL)
      if refresh_base and refresh_base ~= "" then
        local refresh_token = self.settings and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_TOKEN)
        local cookie_url = refresh_base:gsub("/+$", "") .. "/cookie"
        logger.info("Goodreads: no session cookie configured, trying local cookie-refresher at " .. cookie_url)
        local cookie, refresher_code = fetch_cached_cookie(cookie_url, refresh_token, timeout)
        if cookie then
          headers["Cookie"] = cookie
          refreshed_cookie = cookie
          logger.info("Goodreads: bootstrapped session cookie from local cookie-refresher")
        else
          logger.warn("Goodreads: cookie-refresher at " .. cookie_url .. " didn't return a cookie (HTTP "
            .. tostring(refresher_code) .. " -- " .. refresher_failure_hint(refresher_code) .. ")")
        end
      end
    end

    if headers["Cookie"] then
      logger.info("Goodreads: Final Cookie length: " .. #headers["Cookie"])
    end

    if method == "POST" and body then
      if not headers["Content-Type"] then
        headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
      headers["Content-Length"] = tostring(#body)
    end

    -- Goodreads relies on a couple of real 30x redirects as part of normal
    -- navigation, not just error handling: signing in bootstraps the Rails
    -- session with a self-redirect back to the same URL, and a search with
    -- exactly one match (eg. by ISBN) redirects straight to the book page
    -- instead of returning a results list. Only GET/HEAD are auto-followed,
    -- matching real browser behaviour for 301/302/303.
    local current_url = url
    local current_method = method or "GET"
    local max_hops = 5
    local code, _headers, response_body
    local waf_retried = false

    for hop = 0, max_hops do
      local sink = {}
      socketutil:set_timeout(timeout, maxtime)

      local request = {
        url = current_url,
        method = current_method,
        headers = headers,
        source = (current_method == "POST" and body) and ltn12.source.string(body) or nil,
        sink = socketutil.table_sink(sink),
      }

      if current_method == "POST" then
        logger.info("Goodreads: POST URL: " .. current_url)
        logger.info("Goodreads: POST Body: " .. (body or "nil"))
      end

      local ok
      ok, code, _headers = http.request(request)
      socketutil:reset_timeout()

      if type(code) ~= "number" and self.settings then
        self.settings:debugWarn("Goodreads: http.request to " .. current_url .. " failed - ok="
          .. tostring(ok) .. " code=" .. tostring(code))
      end

      response_body = table.concat(sink)

      -- Must happen before the redirect decision below: the bootstrap
      -- redirect won't resolve unless its own newly issued cookie is
      -- carried into the next hop's request.
      local set_cookie = _headers and _headers["set-cookie"]
      if set_cookie then
        headers["Cookie"] = merge_set_cookie(headers["Cookie"], set_cookie)
      end

      local location = _headers and _headers["location"]
      -- Confirmed via live testing: an anonymous request gets a real 302 for
      -- an exact single-result match (eg. by ISBN), but an authenticated
      -- session -- what this plugin always sends -- gets a 200 with the
      -- same Location header instead, seemingly meant for Goodreads' own
      -- client-side router rather than a raw HTTP client. Treat that the
      -- same as a real redirect so it's still followed to the actual book
      -- page, instead of silently treating whatever body came with that 200
      -- (never a results list) as one.
      local is_redirect = code == 301 or code == 302 or code == 303 or code == 307 or code == 308
        or (code == 200 and location and location ~= current_url)
      local waf_action = _headers and _headers["x-amzn-waf-action"]
      logger.info("Goodreads: hop " .. hop .. " url=" .. current_url .. " code=" .. tostring(code)
        .. " location=" .. tostring(location) .. " set_cookie=" .. tostring(set_cookie ~= nil)
        .. " waf_action=" .. tostring(waf_action))
      local waf_retry_now = false
      if waf_action then
        -- Stored setting is just the refresher's base URL (e.g.
        -- http://192.168.1.50:5080) -- the /refresh path is always the
        -- same, so there's no reason to make the user type it.
        local refresh_base = self.settings and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL)
        local refresh_url = refresh_base and refresh_base ~= "" and (refresh_base:gsub("/+$", "") .. "/refresh")
        local refresh_token = self.settings and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_TOKEN)
        if refresh_url and not waf_retried then
          waf_retried = true
          logger.info("Goodreads: WAF challenge hit, trying local cookie-refresher at " .. refresh_url)
          local fresh_cookie, refresher_code = fetch_refreshed_cookie(refresh_url, refresh_token, timeout)
          if fresh_cookie and fresh_cookie ~= headers["Cookie"] then
            headers["Cookie"] = fresh_cookie
            refreshed_cookie = fresh_cookie
            waf_retry_now = true
            logger.info("Goodreads: got a refreshed cookie, retrying")
          else
            logger.warn("Goodreads: cookie-refresher at " .. refresh_url .. " didn't return a usable cookie (HTTP "
              .. tostring(refresher_code) .. " -- " .. refresher_failure_hint(refresher_code) .. ")")
          end
        else
          logger.warn("Goodreads: request blocked by AWS WAF bot-challenge (not a code bug -- "
            .. "the saved session cookie's challenge token is stale/rejected; needs a fresh "
            .. "browser-solved cookie capture, retrying won't help)")
        end
      end

      if is_redirect and location and hop < max_hops
          and (current_method == "GET" or current_method == "HEAD") then
        if location:match("^https?://") then
          current_url = location
        elseif location:sub(1, 1) == "/" then
          local scheme_host = current_url:match("^(https?://[^/]+)")
          current_url = (scheme_host or base_url) .. location
        else
          current_url = location
        end
      elseif waf_retry_now and hop < max_hops then
        -- current_url/current_method unchanged: same request, fresh cookie
      else
        break
      end
    end

    local header_str = ""
    if _headers then
      for k, v in pairs(_headers) do
        header_str = header_str .. k .. "=" .. tostring(v) .. "\n"
      end
    end
    -- Smuggled through as a pseudo-header so callers that care which URL a
    -- request actually landed on after redirects can read
    -- headers["x-final-url"].
    header_str = header_str .. "x-final-url=" .. current_url .. "\n"
    -- Same trick: a cookie pulled from the local refresher above was only
    -- ever applied to this subprocess's own copy of `headers` -- surface it
    -- so the parent (which owns self.settings) can persist it for next time.
    if refreshed_cookie then
      header_str = header_str .. "x-refreshed-cookie=" .. refreshed_cookie .. "\n"
    end
    -- header_str's length is prefixed (rather than relying on a "|"
    -- delimiter to find where it ends) because it can itself contain "|" --
    -- e.g. the refreshed-cookie value above, which per RFC 6265 is legally
    -- allowed to contain one, and real Amazon-linked session tokens do.
    -- Scanning for the next "|" would silently truncate it mid-cookie.
    return (code or "error") .. "|" .. #header_str .. "|" .. header_str .. response_body
  end

  -- One retry recovers most transient subprocess-fork failures, mirroring
  -- StoryGraph's request().
  local completed, content
  for attempt = 1, 2 do
    completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
    if completed then break end
    if self.settings and attempt == 1 then
      self.settings:debugWarn("Goodreads: request() subprocess did not complete on first attempt for "
        .. url .. ", retrying once")
    end
  end

  if completed and content then
    local code, header_len, rest = string.match(content, "^([^|]*)|(%d+)|(.*)")
    local header_str, response
    if header_len then
      header_len = tonumber(header_len)
      header_str = rest:sub(1, header_len)
      response = rest:sub(header_len + 1)
    end
    local headers = {}
    if header_str then
      for line in header_str:gmatch("[^\r\n]+") do
        local k, v = line:match("([^=]*)=(.*)")
        if k then headers[k:lower()] = v end
      end
    end
    local code_num = tonumber(code)

    local redirect = headers["location"] or ""
    if code_num == 401 or redirect:match("signin") or redirect:match("sign_in") then
      self:notifyAuthFailure()
      return code_num, response, headers, "Unauthorized"
    end

    -- self.settings only exists here in the parent, not inside the forked
    -- subprocess above -- so a cookie the local refresher handed us mid-hop
    -- gets persisted here instead, mirroring StoryGraph's own refreshed-
    -- session save.
    if headers["x-refreshed-cookie"] and self.settings then
      logger.info("Goodreads: saving refreshed cookie from local cookie-refresher")
      self.settings:updateSetting(SETTING.GOODREADS.SESSION_COOKIE, headers["x-refreshed-cookie"])
    end

    return code_num, response, headers
  end
  if self.settings then
    self.settings:debugWarn("Goodreads: request() subprocess did not complete - completed="
      .. tostring(completed) .. " content_present=" .. tostring(content ~= nil) .. " url=" .. url)
  end
  return nil, "Request failed"
end

-- Warn (once per cooldown) that the stored session cookie is dead
function GoodreadsApi:notifyAuthFailure()
  local now = os.time()
  if self.last_auth_warning and now - self.last_auth_warning < 300 then
    return
  end
  self.last_auth_warning = now
  if self.on_error then
    self.on_error("Unauthorized")
  end
end

-- Fetches the classic homepage, which is the only page that reliably serves
-- both a Rails CSRF meta tag and a plain nav link to the viewer's own legacy
-- profile id (the book/search pages are Next.js-rendered and expose
-- neither), caching both on self so every write only needs one extra GET.
function GoodreadsApi:refreshSession()
  local code, html = self:request(base_url .. "/", "GET")
  if code == 200 and html then
    self:extract_csrf(html)
    local uid = html:match("/user/show/(%d+)")
    if uid then self.last_user_id = uid end
  end
  return self.last_csrf, self.last_user_id
end

function GoodreadsApi:me()
  self:refreshSession()
  return { id = self.last_user_id or "goodreads_user" }
end

function GoodreadsApi:findBooks(title, author, _userId)
  local query = title
  if author and author ~= "" then query = query .. " " .. author end
  local search_url = base_url .. "/search?q=" .. urlencode(query)
  local code, html, resp_headers = self:request(search_url, "GET")

  if code ~= 200 or not html then
    if resp_headers and resp_headers["x-amzn-waf-action"] then
      return {}, "Search blocked by Goodreads bot-challenge (WAF) -- try a fresh session cookie"
    end
    logger.warn("Goodreads search failed. Code:", code)
    return {}, "Search failed with code " .. (code or "unknown")
  end

  -- An exact single match (eg. an ISBN search) doesn't return a
  -- search-results page at all -- Goodreads 302s straight to the book page,
  -- which request() now follows transparently. Detect landing on
  -- /book/show/{id} here and build a single result from that page's JSON-LD
  -- data instead of running the search-results card parser below against
  -- HTML that was never a results list to begin with.
  local final_url = resp_headers and resp_headers["x-final-url"]
  local redirected_book_id = final_url and final_url:match("/book/show/(%d+)")
  if redirected_book_id then
    local book_data = parse_ldjson_book(html)
    if not book_data then return {} end
    return {
      {
        book_id = redirected_book_id,
        title = book_data.title,
        contributions = { { author = { name = book_data.author } } },
        cached_image = { url = book_data.image },
        book_series = {},
        description = "",
      },
    }
  end

  local results = {}
  local seen = {}

  -- The search page is Next.js-rendered, and -- confirmed against real
  -- captured search HTML -- each result's cover image and its title/author
  -- "details" live in two separate DOM sections rather than one contiguous
  -- card (a book's cover marker and its title text can be tens of
  -- thousands of bytes apart). The two sections stay in matching order
  -- though, so book-item-title matches are scraped globally in document
  -- order and zipped positionally against the book-item-kca cover markers
  -- (also collected globally, in document order), instead of slicing the
  -- HTML into per-card chunks.
  local kca_positions = {}
  for pos in html:gmatch('()data%-testid="book%-item%-kca://book/') do
    table.insert(kca_positions, pos)
  end

  local search_pos = 1
  local card_index = 0
  while true do
    local s, e, book_id, title_text = html:find(
      'data%-testid="book%-item%-title"><a href="/book/show/(%d+)[^"]*">(.-)</a>',
      search_pos
    )
    if not s or not e then break end
    search_pos = e + 1
    card_index = card_index + 1

    if book_id and not seen[book_id] then
      seen[book_id] = true
      title_text = decode_entities(title_text)

      local after = html:sub(e, e + 600)
      local author_text = after:match('data%-testid="name">([^<]+)</span>') or "Unknown Author"
      author_text = decode_entities(author_text)

      local cover_url
      local kca_pos = kca_positions[card_index]
      if kca_pos then
        -- Window has to clear the `srcSet` attribute (4 URLs, several
        -- hundred bytes) that comes before the actual `src` one.
        local cover_window = html:sub(kca_pos, kca_pos + 1500)
        cover_url = cover_window:match('data%-testid="responsive%-image"[^>]-src="([^"]+)"')
      end

      table.insert(results, {
        book_id = book_id,
        title = title_text,
        contributions = { { author = { name = author_text } } },
        cached_image = { url = cover_url },
        book_series = {},
        description = "",
      })
    end
  end

  return results
end

function GoodreadsApi:findUserBook(book_id, _user_id)
  if not book_id then return {} end
  local book_url = base_url .. "/book/show/" .. book_id
  local code, html = self:request(book_url, "GET")

  if code ~= 200 or not html then
    return {}, "Failed to fetch book"
  end

  local shelf_name = nil

  if not html:find('"viewerShelving":null', 1, true) then
    -- The book page's embedded Apollo cache only stores the viewer's shelf
    -- assignment as a "__ref" pointer next to other users' shelvings -- the
    -- actual dereferenced Shelving object (with shelf.name) lives elsewhere
    -- in the same cache dump, keyed by that exact same ref string, so find
    -- the ref, then plain-text search for its dereferenced object using it
    -- as a dict key (the ref string contains literal escaped quotes, so a
    -- second pattern-match would need those re-escaped -- a plain substring
    -- search sidesteps that entirely).
    local ref = html:match('"viewerShelving":{"__ref":"(Shelving:.-}})"}')
    if ref then
      local ref_pos = html:find(ref, 1, true)
      local key_pos = ref_pos and html:find(ref, ref_pos + #ref, true)
      if key_pos then
        local window = html:sub(key_pos, key_pos + 4000)
        shelf_name = window:match('"shelf":{"__typename":"Shelf","name":"([%w%-]+)"')
      end
    end
  end

  -- Goodreads' viewerShelving/shelf.name only ever reflects the 3 canonical
  -- exclusive shelves; Paused/Did Not Finish are tracked as non-exclusive
  -- "taggings" whose shape isn't confirmed from available data, so read-back
  -- for those two statuses isn't supported (write-only, via updateUserBook).
  local status_id = nil
  if shelf_name == "to-read" then status_id = 1
  elseif shelf_name == "currently-reading" then status_id = 2
  elseif shelf_name == "read" then status_id = 3
  end

  local book_num_of_pages = tonumber(html:match('"details":{"__typename":"BookDetails".-"numPages":(%d+)')) or 0

  return {
    id = book_id,
    book_id = book_id,
    status_id = status_id,
    book_num_of_pages = book_num_of_pages,
    page_count = book_num_of_pages,
  }
end

function GoodreadsApi:findBookByIdentifiers(identifiers, user_id)
  local isbn = identifiers and (identifiers.isbn_13 or identifiers.isbn_10)
  if not isbn then return nil end

  local results = self:findBooks(isbn, nil, user_id)
  if results and #results > 0 then
    return results[1]
  end
  return nil
end

function GoodreadsApi:updateUserBook(book_id, status_id)
  local status_map = {
    [1] = "to-read",
    [2] = "currently-reading",
    [3] = "read",
    [4] = "paused",
    [5] = "did-not-finish",
  }
  local shelf = status_map[status_id] or "currently-reading"

  local csrf = self:refreshSession()
  if not csrf then
    logger.warn("Goodreads: Could not extract CSRF token for shelf update")
    return nil
  end

  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["X-Prototype-Version"] = "1.7",
    ["Accept"] = "text/javascript, text/html, application/xml, text/xml, */*",
    ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
    ["Referer"] = base_url .. "/",
    ["Origin"] = base_url,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Dest"] = "empty",
  }

  local code, resp = self:request(base_url .. "/shelf/add_to_shelf", "POST", {
    book_id = book_id,
    name = shelf,
    a = "",
  }, custom_headers)
  self.settings:debugLog("Goodreads: updateUserBook POST response code=" .. tostring(code))

  if code and code >= 200 and code < 300 then
    return self:findUserBook(book_id)
  end
  self.settings:debugWarn("Goodreads: updateUserBook failed - code=" .. tostring(code) .. " resp=" .. tostring(resp))
  return nil
end

-- Unshelves a book entirely (confirmed via HAR of the classic "Edit review"
-- page's remove action -- /review/destroy/{id}, a plain Rails form POST, not
-- the WAF-gated GraphQL unshelveBook mutation the modern shelf grid uses for
-- the same action). The `{id}` here is the book id, not a separate review
-- id: the captured request used the same numeric id as the book's own
-- /book/show/ page and cover image, so there's no distinct review id to look
-- up first.
function GoodreadsApi:removeRead(book_id)
  local csrf = self:refreshSession()
  if not csrf then
    logger.warn("Goodreads: Could not extract CSRF token for remove")
    return nil
  end

  local custom_headers = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Referer"] = base_url .. "/review/edit/" .. book_id,
    ["Origin"] = base_url,
  }

  local code = self:request(base_url .. "/review/destroy/" .. book_id, "POST", {
    _method = "post",
    authenticity_token = csrf,
  }, custom_headers)

  if code == 200 or code == 302 then
    return { id = book_id }
  end
  self.settings:debugWarn("Goodreads: removeRead failed - code=" .. tostring(code))
  return nil
end

-- /user_status.json takes either field directly, so a percentage update
-- doesn't need a known page count to convert against -- unlike the old
-- percentToPage route, this works even for editions where the numPages
-- scrape in findUserBook comes back 0.
function GoodreadsApi:updateProgress(book_id, value, update_type, note)
  local csrf = self:refreshSession()
  if not csrf then
    logger.warn("Goodreads: Could not extract CSRF token for progress update")
    return nil
  end

  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "*/*",
    ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
    ["Referer"] = base_url .. "/",
    ["Origin"] = base_url,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Dest"] = "empty",
  }

  local progress_field = update_type == "pages" and "user_status[page]" or "user_status[percent]"

  local code, resp = self:request(base_url .. "/user_status.json", "POST", {
    ["user_status[book_id]"] = book_id,
    [progress_field] = value,
    ["user_status[body]"] = note or "",
  }, custom_headers)
  self.settings:debugLog("Goodreads: updateProgress POST response code=" .. tostring(code))

  if code and code >= 200 and code < 300 then
    return self:findUserBook(book_id)
  end
  self.settings:debugWarn("Goodreads: updateProgress failed - code=" .. tostring(code) .. " resp=" .. tostring(resp))
  return nil
end

-- Goodreads' "status update" (/user_status.json's `body` field) is a short
-- feed-post note attached to a progress update, not a book review, so this
-- is really just updateProgress with a note attached -- there's no richer
-- journal concept to map onto here.
function GoodreadsApi:createJournalEntry(data)
  local book_id = data.book_id
  if not book_id then return nil end

  return self:updateProgress(book_id, tonumber(data.progress) or 0, data.progress_type, data.entry)
end

return GoodreadsApi
