-- Goodreads has no official public API, so this mirrors StoryGraph's
-- approach of replaying browser requests. Most Goodreads operations still
-- use Rails/AJAX endpoints, but review text is now saved through a Next.js
-- Server Action discovered from the current editor page's client chunks.
-- Two quirks specific to Goodreads, relative to StoryGraph:
--
-- 1. Goodreads accounts are linked through Amazon, so a valid session is a
--    bundle of ~13 cookies across goodreads.com and Amazon's own domains,
--    not a couple of named values. Rather than trying to parse/merge that
--    bundle, the whole raw `Cookie` header is stored and replayed verbatim
--    as one opaque blob (SETTING.GOODREADS.SESSION_COOKIE). Cookies set by
--    responses aren't saved back to it, but request() keeps them in memory
--    for later requests to Goodreads, so a write sends the cookies that came
--    with its CSRF token. Without them, shelf changes could get Goodreads'
--    generic 404 page (#28).
-- 2. The book page (/book/show/{id}) and search page are server-rendered
--    Next.js/Apollo, not classic Rails forms, so there's no HTML form to
--    scrape a CSRF token from directly -- but the plain homepage (`/`) still
--    is classic Rails, and conveniently also exposes the viewer's legacy
--    numeric user id in a nav link, so one GET of `/` covers both `me()`
--    and CSRF-priming for a write.
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local config = (config_ok and shelfsync_config.goodreads) or {}
local logger = require("shelfsync/lib/common/safe_logger")
local math = require("math")
local os = require("os")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local SETTING = require("shelfsync/lib/common/constants/settings")
local _t = require("shelfsync/lib/common/table_util")

local base_url = "https://www.goodreads.com"

-- Goodreads cookies are stored as one opaque header, so their original
-- per-cookie domain and path scopes are unavailable. Keep that header on the
-- exact HTTPS origin it was copied from.
local function is_goodreads_origin(url)
  if type(url) ~= "string" then return false end
  local scheme, authority = url:match("^([%a][%w+%.%-]*)://([^/%?#]*)")
  if not scheme or not authority or scheme:lower() ~= "https" then return false end
  authority = authority:lower()
  return authority == "www.goodreads.com" or authority == "www.goodreads.com:443"
end

local function remove_cookie_headers(headers)
  for name in pairs(headers) do
    if type(name) == "string" and name:lower() == "cookie" then
      headers[name] = nil
    end
  end
end

local function resolve_redirect(current_url, location)
  if type(location) ~= "string" or location == "" then return nil end
  if location:match("^[%a][%w+%.%-]*:") then return location end

  local scheme, authority, path = current_url:match("^([%a][%w+%.%-]*)://([^/%?#]+)([^?#]*)")
  if not scheme or not authority then return nil end
  local origin = scheme .. "://" .. authority
  if location:sub(1, 2) == "//" then
    return scheme .. ":" .. location
  elseif location:sub(1, 1) == "/" then
    return origin .. location
  end

  path = path ~= "" and path or "/"
  if location:sub(1, 1) == "?" then return origin .. path .. location end
  if location:sub(1, 1) == "#" then return origin .. path .. location end

  local directory = path:match("^(.*)/") or ""
  if directory == "" then directory = "/" else directory = directory .. "/" end
  return origin .. directory .. location
end

local function is_sign_in_url(url)
  if type(url) ~= "string" then return false end
  local lower_url = url:lower()
  return lower_url:find("/user/sign_in", 1, true) ~= nil
    or lower_url:find("signin", 1, true) ~= nil
end

local function is_sign_in_page(body)
  if type(body) ~= "string" then return false end
  local lower_body = body:lower()
  return lower_body:find("something wrong with your goodreads cookie", 1, true) ~= nil
    or (lower_body:find("/user/sign_in", 1, true) ~= nil
      and lower_body:find('name="email"', 1, true) ~= nil)
end

local GoodreadsApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
}

local function request_field_names(data)
  if type(data) ~= "table" then
    return "unknown"
  end
  local names = {}
  for key in pairs(data) do
    names[#names + 1] = tostring(key)
  end
  table.sort(names)
  return table.concat(names, ",")
end

-- The stored session cookie, or the legacy config fallback
local function saved_cookie(self)
  local cookie = ""

  if self.settings then
    cookie = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE)
  end
  if not cookie or cookie == "" then cookie = config.cookie or "" end
  return cookie
end

-- Drops the cookies kept from responses (see the top of this file). A
-- request already out doesn't keep those from its response either.
local function forget_session(self)
  self.session_cookie = nil
  self.session_generation = (self.session_generation or 0) + 1
end

-- Private helper to build headers with cookies
local function get_headers(self, custom_headers)
  local cookie = saved_cookie(self)
  -- With what Goodreads has set since (see the top of this file), unless the
  -- saved cookie was changed or removed in the meantime.
  local session = self.session_cookie
  if session and cookie ~= "" and session.saved == cookie then
    cookie = session.cookie
  end

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

-- Check for a stored cookie or configured refresher without triggering a
-- network request or the "no session cookie" warning log.
function GoodreadsApi:hasCredential()
  local cookie = ""
  if self.settings then
    cookie = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE)
  end
  if not cookie or cookie == "" then cookie = config.cookie or "" end
  local refresh_url = self.settings
    and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL)
  return cookie ~= "" or (refresh_url ~= nil and refresh_url ~= "")
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

-- Hits the refresher's /refresh endpoint to force a freshly browser-solved
-- cookie when Goodreads rejects the current session.
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

-- The classic "Edit review" page (/review/edit/{id}) is a full Rails form,
-- unlike the Next.js book page -- setDateFinished scrapes two things off it:
-- whether a finished reading session already exists (so it can skip adding
-- a duplicate one), and the review/notes text already on it, since the
-- date-finished POST below re-submits the whole review form and would wipe
-- both fields if they weren't echoed back unchanged.
local function parse_review_edit(html)
  if not html or html == "" then return nil end
  local session_count = html:match("data%-count=['\"](%d+)['\"][^>]-id=['\"]readingSessionsCount['\"]")
    or html:match("id=['\"]readingSessionsCount['\"][^>]-data%-count=['\"](%d+)['\"]")
  local review_text = html:match("name=['\"]review%[review%]['\"][^>]*>(.-)</textarea>")
  local notes = html:match("name=['\"]review%[notes%]['\"][^>]*>(.-)</textarea>")
  return {
    session_count = tonumber(session_count) or 0,
    review_text = review_text or "",
    notes = decode_entities(notes or ""),
  }
end

local function html_attribute(tag, name)
  local _, value_start = tag:lower():find("%s" .. name:lower() .. "%s*=%s*")
  if not value_start then return nil end

  local rest = tag:sub(value_start + 1)
  local quote = rest:sub(1, 1)
  if quote == "\"" or quote == "'" then
    local value_end = rest:find(quote, 2, true)
    return value_end and rest:sub(2, value_end - 1) or nil
  end
  return rest:match("^([^%s>]+)")
end

local function has_review_field(body)
  for tag in body:gmatch("<[^>]+>") do
    local name = html_attribute(tag, "name")
    if name and name:lower() == "review[review]" then
      return true
    end
  end
  return false
end

local function parse_review_update_target(html, edit_url)
  local stats = { form_count = 0, review_form = false, missing_action = false, rejected_action = false }
  if not html or html == "" then return nil, nil, stats end

  local lower_html = html:lower()
  local pos = 1
  while true do
    local form_start = lower_html:find("<form[%s>]", pos)
    if not form_start then break end
    local tag_end = lower_html:find(">", form_start, true)
    if not tag_end then break end
    local close_start, close_end = lower_html:find("</form%s*>", tag_end + 1)
    if not close_start then break end

    stats.form_count = stats.form_count + 1
    local opening_tag = html:sub(form_start, tag_end)
    local body = html:sub(tag_end + 1, close_start - 1)
    if has_review_field(body) then
      stats.review_form = true
      local action = html_attribute(opening_tag, "action")
      if action == "" then action = nil end
      if action then action = decode_entities(action) end

      local method = nil
      for tag in body:gmatch("<[^>]+>") do
        if tag:lower():match("^<input[%s>]")
            and (html_attribute(tag, "name") or ""):lower() == "_method" then
          method = html_attribute(tag, "value")
          break
        end
      end

      if action and (action:match("^/review[/?.]") or action == "/review"
          or action:match("^https://www%.goodreads%.com/review[/?.]")) then
        return action, method, stats
      elseif not action then
        stats.missing_action = true
        -- An HTML form with no action submits to its current page. Use that
        -- browser-defined target only when the form explicitly posts.
        if (html_attribute(opening_tag, "method") or ""):lower() == "post" then
          return edit_url, method, stats
        end
      elseif action then
        stats.rejected_action = true
      end
    end
    pos = close_end + 1
  end

  local review_id = html:match("edit_review_(%d+)")
  if review_id then return "/review/" .. review_id, "put", stats end
  return nil, nil, stats
end

-- The current Goodreads review editor is a Next.js app. Its mutation IDs are
-- compiled into the client chunks and can rotate between builds, so discover
-- the actions from the script URLs on the editor page instead of pinning IDs
-- copied from one HAR. The editor loads its page chunk last; walking scripts
-- backwards finds its action chunks before downloading unrelated site code.
local REVIEW_SERVER_ACTIONS = { "submitReviewFormAction" }

local function balanced_json_end(text, start)
  local stack = {}
  local quoted, escaped = false, false
  for pos = start, #text do
    local char = text:sub(pos, pos)
    if quoted then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = false
      end
    elseif char == '"' then
      quoted = true
    elseif char == "{" then
      stack[#stack + 1] = "}"
    elseif char == "[" then
      stack[#stack + 1] = "]"
    elseif char == "}" or char == "]" then
      if stack[#stack] ~= char then return nil end
      stack[#stack] = nil
      if #stack == 0 then return pos end
    end
  end
  return nil
end

local function decode_json_value_at(text, start)
  while start <= #text and text:sub(start, start):match("%s") do
    start = start + 1
  end
  local first = text:sub(start, start)
  local finish
  if first == '"' then
    local escaped = false
    for pos = start + 1, #text do
      local char = text:sub(pos, pos)
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        finish = pos
        break
      end
    end
  elseif first == "{" or first == "[" then
    finish = balanced_json_end(text, start)
  else
    finish = start
    while finish <= #text do
      local char = text:sub(finish, finish)
      if char == "," or char == "}" or char == "]" or char:match("%s") then break end
      finish = finish + 1
    end
    finish = finish - 1
  end
  if not finish or finish < start then return nil end
  local ok, value = pcall(json.decode, text:sub(start, finish), json.decode.simple)
  if ok then return value, finish end
  return nil
end

local function extract_json_property(text, name, expected_type)
  local needle = '"' .. name .. '":'
  local pos = 1
  while true do
    local key_start = text:find(needle, pos, true)
    if not key_start then return nil end
    local value, value_end = decode_json_value_at(text, key_start + #needle)
    if value_end and (not expected_type or type(value) == expected_type) then
      return value
    end
    pos = key_start + #needle
  end
end

local function parse_next_flight(html)
  local rows = {}
  for script in html:gmatch("<script[^>]*>(.-)</script%s*>") do
    local search_from = 1
    while true do
      local push_at = script:find("self.__next_f.push", search_from, true)
      if not push_at then break end
      local array_start = script:find("[", push_at + #"self.__next_f.push", true)
      local array_end = array_start and balanced_json_end(script, array_start)
      if not array_end then break end
      local ok, payload = pcall(json.decode, script:sub(array_start, array_end), json.decode.simple)
      if ok and type(payload) == "table" and payload[1] == 1 and type(payload[2]) == "string" then
        rows[#rows + 1] = payload[2]
      end
      search_from = array_end + 1
    end
  end
  if #rows == 0 then return nil end
  return table.concat(rows, "\n")
end

local function parse_next_chunk_paths(html)
  local paths, seen = {}, {}
  for tag in html:gmatch("<script[^>]*>") do
    local src = html_attribute(tag, "src")
    if src then
      src = decode_entities(src)
      local path = src:match("^https://www%.goodreads%.com(/_next/static/chunks/[^?#]+)$") or src
      local unrelated_chunk = path:find("/polyfills-", 1, true)
        or path:find("/webpack-", 1, true)
        or path:find("/app/not-found-", 1, true)
        or path:find("/app/review/edit/", 1, true) and path:find("/error-", 1, true)
      if path:sub(1, #"/_next/static/chunks/") == "/_next/static/chunks/"
          and path:sub(-3) == ".js" and not path:find("..", 1, true)
          and not unrelated_chunk and not seen[path] then
        paths[#paths + 1] = path
        seen[path] = true
      end
    end
  end
  return paths
end

local function find_server_action_id(source, action_name)
  local label = '"' .. action_name .. '"'
  local from = 1
  while true do
    local label_at = source:find(label, from, true)
    if not label_at then return nil end
    local prefix_start = math.max(1, label_at - 220)
    local prefix = source:sub(prefix_start, label_at - 1)
    local marker = prefix:match(".*()createServerReference")
    if marker then
      local call = prefix:sub(marker) .. source:sub(label_at, label_at + #label - 1)
      local action_id = call:match("createServerReference[^%(]*%(%s*[\"']([%x]+)[\"']")
      if action_id and #action_id >= 32 then return action_id end
    end
    from = label_at + #label
  end
end

local function get_next_review_action_id(self, html, referer)
  local paths = parse_next_chunk_paths(html)
  if #paths == 0 then return nil end
  local cache_key = table.concat(paths, "\n")
  local cache = self.goodreads_review_action_cache
  if not cache or cache.key ~= cache_key then
    cache = { key = cache_key, ids = {}, checked = {} }
    self.goodreads_review_action_cache = cache
  end
  if cache.ids.submitReviewFormAction then return cache.ids.submitReviewFormAction end

  for index = #paths, 1, -1 do
    local path = paths[index]
    if not cache.checked[path] then
      local code, source = self:request(base_url .. path, "GET", nil, {
        ["Accept"] = "*/*",
        ["Referer"] = referer,
        ["Sec-Fetch-Site"] = "same-origin",
        ["Sec-Fetch-Mode"] = "no-cors",
        ["Sec-Fetch-Dest"] = "script",
      })
      if code == 200 and type(source) == "string" then
        cache.checked[path] = true
        for _, known_action in ipairs(REVIEW_SERVER_ACTIONS) do
          local id = find_server_action_id(source, known_action)
          if id then cache.ids[known_action] = id end
        end
      elseif code == 202 then
        -- A WAF challenge affects every asset fetch; stop instead of retrying
        -- the same blocked request across the rest of the page's chunks.
        return nil
      end
    end
    if cache.ids.submitReviewFormAction then return cache.ids.submitReviewFormAction end
  end
  return nil
end

local function parse_next_review_state(html)
  local flight = parse_next_flight(html)
  if not flight then return nil end

  local sessions = extract_json_property(flight, "readingSessions", "table")
  if not sessions then
    local ok, empty = pcall(json.decode, "[]", json.decode.simple)
    sessions = ok and empty or {}
  end
  local book_id = (sessions[1] and sessions[1].bookId)
    or flight:match('"bookId":"(kca://book/.-)"')
    or flight:match('"id":"(kca://book/.-)"')
  if not book_id then return nil end

  local private_notes = extract_json_property(flight, "initialPrivateNotes", "string")
    or extract_json_property(flight, "privateNotes", "string") or ""
  local post_to_blog = extract_json_property(flight, "initialPostToBlog", "boolean")
  local add_to_feed = extract_json_property(flight, "initialAddToUpdateFeed", "boolean")
  local spoiler_status = extract_json_property(flight, "spoilerStatus", "boolean")
  local is_already_owned = extract_json_property(flight, "isAlreadyOwned", "boolean")

  return {
    book_id = book_id,
    reading_sessions = sessions,
    private_notes = private_notes,
    post_to_blog = post_to_blog == true,
    add_to_feed = add_to_feed ~= false,
    spoiler_status = spoiler_status == true,
    is_owned_edition = is_already_owned == true,
  }
end

local function next_review_action_headers(action_id, book_id, edit_url)
  -- This is Next.js' serialized App Router tree for /review/edit/[id].
  -- The dynamic route segment is the Goodreads legacy book ID.
  local router_tree = '["",{"children":["review",{"children":["edit",{"children":[["id","'
    .. tostring(book_id) .. '","d"],{"children":["__PAGE__",{},null,null]},null,null]}]},null,null]},null,null,true]'
  return {
    ["Accept"] = "text/x-component",
    ["Content-Type"] = "text/plain;charset=UTF-8",
    ["Next-Action"] = action_id,
    ["Next-Router-State-Tree"] = urlencode(router_tree),
    ["Referer"] = edit_url,
    ["Origin"] = base_url,
    ["Sec-Fetch-Site"] = "same-origin",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Dest"] = "empty",
  }
end

local function next_action_has_no_errors(response)
  local error_ref = response:match('"errors":"%$Q([%w]+)"')
  if not error_ref then return true end
  local error_row = response:match("[\r\n]" .. error_ref .. ":([^\r\n]+)")
  if not error_row then return false end
  local ok, errors = pcall(json.decode, error_row, json.decode.simple)
  return ok and type(errors) == "table" and #errors == 0
end

local function submit_next_review_text(self, book_id, text, edit_url, edit_html, state)
  if not state then
    return nil, "Could not read the Goodreads review editor state; review text was not saved"
  end

  local action_id = get_next_review_action_id(self, edit_html, edit_url)
  if not action_id then
    if self.settings then
      self.settings:debugWarn("Goodreads: could not find submitReviewFormAction in the review page assets")
    end
    return nil, "Could not identify Goodreads' current review-save action; review text was not saved"
  end

  local payload = {
    bookId = state.book_id,
    reviewText = text,
    spoilerStatus = state.spoiler_status,
    isOwnedEdition = state.is_owned_edition,
    privateNotes = state.private_notes,
    postToBlog = state.post_to_blog,
    addToUpdateFeed = state.add_to_feed,
    readingSessions = state.reading_sessions,
    initialReadingSessions = "$0:0:readingSessions",
  }
  local body = json.encode({ payload, "/review/edit/[id]" })
  if #state.reading_sessions == 0 then
    -- Some Lua JSON encoders serialize an unmarked empty table as an object;
    -- the Server Action expects the browser's empty readingSessions array.
    body = body:gsub('("readingSessions":)%s*{}', "%1[]")
  end
  local code, response = self:request(edit_url, "POST", body,
    next_review_action_headers(action_id, book_id, edit_url))
  self.settings:debugLog("Goodreads: Next.js review submit response code=" .. tostring(code)
    .. " response_length=" .. tostring(type(response) == "string" and #response or 0))

  local has_saved_review = type(response) == "string"
    and response:match('"legacyId":"%d+"') ~= nil
  if code == 200 and has_saved_review and next_action_has_no_errors(response) then
    return true
  end

  self.settings:debugWarn("Goodreads: Next.js review submit did not confirm a saved review (HTTP "
    .. tostring(code) .. ")")
  return nil, "Goodreads did not confirm saving the review (HTTP " .. tostring(code) .. ")"
end

-- Row id from GET /reading_sessions/new?book_id= (an HTML table row
-- fragment), needed to name the date-picker fields in the follow-up POST.
local function parse_new_session_rowid(html)
  if not html or html == "" then return nil end
  return html:match("data%-rowid=['\"]([^'\"]+)['\"]")
end

-- Extracts the authenticity token from a classic Goodreads HTML page. Normal
-- callers may reuse the cached value if parsing fails; connection checks pass
-- fresh_only so an old token cannot make a stale cookie look valid.
function GoodreadsApi:extract_csrf(html, fresh_only)
  if not html then
    if fresh_only then return nil end
    return self.last_csrf
  end

  local csrf = html:match('<meta%s+[^>]*name=["\']csrf%-token["\']%s+[^>]*content=["\']([^"\']+)["\']')
            or html:match('<meta%s+[^>]*content=["\']([^"\']+)["\']%s+[^>]*name=["\']csrf%-token["\']')
            -- /review/edit doesn't carry the layout meta tag the homepage does,
            -- only the classic Rails form's own hidden input.
            or html:match('name=["\']authenticity_token["\']%s+value=["\']([^"\']+)["\']')

  if csrf then
    self.last_csrf = csrf
  end

  if fresh_only and not csrf then return nil end
  return csrf or self.last_csrf
end

function GoodreadsApi:request(url, method, data, custom_headers, request_options)
  if not NetworkManager:isConnected() or not self.enabled then
    if self.settings then
      self.settings:debugWarn("Goodreads: request() aborted before sending - NetworkManager connected="
        .. tostring(NetworkManager:isConnected()) .. " enabled=" .. tostring(self.enabled) .. " url=" .. url)
    end
    return nil, "Network not connected"
  end

  local completed, content, sent_saved, sent_generation
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
    if is_goodreads_origin(url) and (not headers["Cookie"] or headers["Cookie"] == "") then
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
      logger.info("Goodreads: POST request fields=" .. request_field_names(data)
        .. " body_length=" .. #body)
    end

    -- Goodreads relies on a couple of real 30x redirects as part of normal
    -- navigation, not just error handling: signing in bootstraps the Rails
    -- session with a self-redirect back to the same URL, and a search with
    -- exactly one match (eg. by ISBN) redirects straight to the book page
    -- instead of returning a results list. This loop follows GET/HEAD redirects
    -- itself so every hop can be restricted to Goodreads' HTTPS origin.
    local current_url = url
    local current_method = method or "GET"
    local max_hops = 5
    local code, _headers, response_body
    local cookie_refresh_attempted = false
    -- Only those Goodreads set, so the parent can add them to whatever it has
    -- kept by the time this is back.
    local set_cookies = ""

    for hop = 0, max_hops do
      -- The request may be initiated by an internal caller with a URL other
      -- than Goodreads. Never attach this opaque credential bundle there.
      if not is_goodreads_origin(current_url) then
        remove_cookie_headers(headers)
      end

      local sink = {}
      socketutil:set_timeout(timeout, maxtime)

      local request = {
        url = current_url,
        method = current_method,
        headers = headers,
        -- LuaSocket otherwise follows GET/HEAD redirects before this loop can
        -- validate their destinations, reusing the same headers table.
        redirect = false,
        source = (current_method == "POST" and body) and ltn12.source.string(body) or nil,
        sink = socketutil.table_sink(sink),
      }

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
        set_cookies = merge_set_cookie(set_cookies, set_cookie)
      end

      local location = _headers and _headers["location"]
      local content_type = _headers and _headers["content-type"] or "unknown"
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
        .. " waf_action=" .. tostring(waf_action) .. " content_type=" .. tostring(content_type)
        .. " response_length=" .. #response_body)
      local cookie_retry_now = false
      local expired_session = code == 401 or code == 403
        or is_sign_in_url(location) or is_sign_in_url(current_url)
        or is_sign_in_page(response_body)
      local refresh_reason = (waf_action or code == 202) and "WAF challenge"
        or (expired_session and "expired session")
      local session_replaced_while_request_was_in_flight = self.session_generation ~= sent_generation
        or saved_cookie(self) ~= sent_saved
      if refresh_reason and is_goodreads_origin(current_url) and session_replaced_while_request_was_in_flight then
        logger.info("Goodreads: rejected response belongs to a replaced session; keeping the newer session")
      elseif refresh_reason and is_goodreads_origin(current_url) then
        -- Stored setting is just the refresher's base URL (e.g.
        -- http://192.168.1.50:5080) -- the /refresh path is always the
        -- same, so there's no reason to make the user type it.
        local refresh_base = self.settings and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL)
        local refresh_url = refresh_base and refresh_base ~= "" and (refresh_base:gsub("/+$", "") .. "/refresh")
        local refresh_token = self.settings and self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_TOKEN)
        if refresh_url and not cookie_refresh_attempted then
          cookie_refresh_attempted = true
          logger.info("Goodreads: " .. refresh_reason .. ", trying local cookie-refresher at " .. refresh_url)
          local fresh_cookie, refresher_code = fetch_refreshed_cookie(refresh_url, refresh_token, timeout)
          if fresh_cookie and fresh_cookie ~= headers["Cookie"] then
            headers["Cookie"] = fresh_cookie
            refreshed_cookie = fresh_cookie
            set_cookies = ""
            cookie_retry_now = true
            logger.info("Goodreads: got a refreshed cookie, retrying")
          else
            logger.warn("Goodreads: cookie-refresher at " .. refresh_url .. " didn't return a usable cookie (HTTP "
              .. tostring(refresher_code) .. " -- " .. refresher_failure_hint(refresher_code) .. ")")
          end
        elseif not cookie_refresh_attempted then
          logger.warn("Goodreads: " .. refresh_reason .. " but no Cookie Auto-Refresh URL is configured")
        else
          logger.warn("Goodreads: " .. refresh_reason .. " persisted after retrying with a refreshed cookie")
        end
      end

      if cookie_retry_now and hop < max_hops then
        -- Retry the same page with the refresher's cookie before following a
        -- sign-in redirect from the rejected session.
      elseif is_redirect and location and hop < max_hops
          and (current_method == "GET" or current_method == "HEAD") then
        local next_url = resolve_redirect(current_url, location)
        if is_goodreads_origin(next_url) then
          current_url = next_url
        else
          logger.warn("Goodreads: refusing redirect outside https://www.goodreads.com")
          break
        end
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
    -- And the cookies Goodreads set along the way, for the parent to send
    -- with the requests that follow. Always written, if only empty, so a
    -- response header of the same name can't stand in for it.
    local session_cookie = is_goodreads_origin(url) and set_cookies or ""
    header_str = header_str .. "x-session-cookie=" .. session_cookie .. "\n"
    -- header_str's length is prefixed (rather than relying on a "|"
    -- delimiter to find where it ends) because it can itself contain "|" --
    -- e.g. the refreshed-cookie value above, which per RFC 6265 is legally
    -- allowed to contain one, and real Amazon-linked session tokens do.
    -- Scanning for the next "|" would silently truncate it mid-cookie.
    return (code or "error") .. "|" .. #header_str .. "|" .. header_str .. response_body
  end

  -- One retry recovers most transient subprocess-fork failures, mirroring
  -- StoryGraph's request().
  for attempt = 1, 2 do
    -- Cookies kept from earlier responses go with the saved cookie they were
    -- set for, so they're dropped once that's changed or removed. This
    -- attempt's are only kept if that's still the one it went out with, and
    -- they weren't forgotten (see forget_session), by the time it's back.
    sent_saved = saved_cookie(self)
    if self.session_cookie and self.session_cookie.saved ~= sent_saved then
      forget_session(self)
    end
    sent_generation = self.session_generation
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
    local session_cookie = headers["x-session-cookie"]
    headers["x-session-cookie"] = nil

    local redirect = headers["location"] or ""
    if code_num == 401 or is_sign_in_url(redirect) then
      -- Unless the cookie it went out with has been replaced since.
      if self.session_generation == sent_generation and saved_cookie(self) == sent_saved then
        forget_session(self)
      end
      if not (request_options and request_options.suppress_auth_error) then
        self:notifyAuthFailure()
      end
      return code_num, response, headers, "Unauthorized"
    end

    -- self.settings only exists here in the parent, not inside the forked
    -- subprocess above -- so a cookie the local refresher handed us mid-hop
    -- gets persisted here instead, mirroring StoryGraph's own refreshed-
    -- session save.
    if headers["x-refreshed-cookie"] and self.settings then
      logger.info("Goodreads: saving refreshed cookie from local cookie-refresher")
      self.settings:updateSetting(SETTING.GOODREADS.SESSION_COOKIE, headers["x-refreshed-cookie"])
      -- CSRF tokens may be tied to the cookie session that fetched them.
      self.last_csrf = nil
    end

    -- Kept for the saved cookie the request went out with, or the refresher's
    -- replacement, which also replaces any kept before. Added to those kept
    -- since it went out, which may have come from requests sent after it.
    local refreshed = headers["x-refreshed-cookie"]
    if refreshed then
      forget_session(self)
      sent_saved, sent_generation = refreshed, self.session_generation
    end
    if session_cookie and session_cookie ~= "" and self.session_generation == sent_generation
        and saved_cookie(self) == sent_saved then
      local kept = self.session_cookie
      local cookie = kept and kept.saved == sent_saved and kept.cookie or sent_saved
      self.session_cookie = { saved = sent_saved, cookie = merge_set_cookie(cookie, session_cookie) }
    end

    return code_num, response, headers
  end
  if self.settings then
    self.settings:debugWarn("Goodreads: request() subprocess did not complete - completed="
      .. tostring(completed) .. " content_present=" .. tostring(content ~= nil) .. " url=" .. url)
  end
  return nil, "Request failed"
end

-- Read-only account check, mirroring the separate Goodreads plugin's GET
-- /review/list probe. request() bootstraps a missing cookie from /cookie and
-- retries an expired/WAF-blocked session through the configured refresher.
function GoodreadsApi:testConnection()
  if not self:hasCredential() then
    return { ok = false, error = "no_cookies" }
  end
  if not NetworkManager:isConnected() then
    return { ok = false, error = "no_network" }
  end

  local html_headers = {
    ["Accept"] = "text/html,application/xhtml+xml",
    ["X-Requested-With"] = nil,
  }
  local code, body, headers, request_error = self:request(
    base_url .. "/review/list",
    "GET",
    nil,
    html_headers,
    { suppress_auth_error = true }
  )

  headers = headers or {}
  if code == 202 or headers["x-amzn-waf-action"] then
    return { ok = false, error = "waf_challenge" }
  end

  local final_url = headers["x-final-url"] or ""
  local location = headers.location or ""
  if code == 401 or code == 403 or request_error == "Unauthorized"
      or is_sign_in_url(final_url) or is_sign_in_url(location) or is_sign_in_page(body) then
    return { ok = false, error = "session_expired" }
  end

  if code == 200 and body and self:extract_csrf(body, true) then
    local user_id = body:match("/user/show/(%d+)")
    if user_id then self.last_user_id = user_id end
    return {
      ok = true,
      user_id = user_id,
      cookie_refreshed = headers["x-refreshed-cookie"] ~= nil,
    }
  end

  if not code then
    return { ok = false, error = request_error or "connection_failed" }
  end
  if code == 200 then
    return { ok = false, error = "unexpected_response" }
  end
  return { ok = false, error = "HTTP " .. tostring(code) }
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
-- request() keeps any cookies this GET sets for the requests that follow.
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

local function find_book_cache(data, book_query)
  if type(data) ~= "table" then return nil end
  if _t.dig(data, "ROOT_QUERY", book_query, "__ref") then return data end
  for _, value in pairs(data) do
    local cache = find_book_cache(value, book_query)
    if cache then return cache end
  end
end

function GoodreadsApi:findUserBook(book_id, _user_id)
  if not book_id then return {} end
  local book_url = base_url .. "/book/show/" .. book_id
  local code, html = self:request(book_url, "GET")

  if code ~= 200 or not html then
    return {}, "Failed to fetch book"
  end

  -- Decode complete script payloads so fields cannot leak between books or
  -- shelving objects. The Apollo cache may be nested in the page's data.
  local book_query = ('getBookByLegacyId({"legacyId":"%s"})'):format(book_id)
  local cache
  for script in html:gmatch("<script[^>]*>(.-)</script>") do
    if script:find("getBookByLegacyId", 1, true) then
      local ok, data = pcall(json.decode, script)
      if ok then cache = find_book_cache(data, book_query) end
      if cache then break end
    end
  end
  local book_ref = _t.dig(cache, "ROOT_QUERY", book_query, "__ref")
  local book = book_ref and cache[book_ref]
  local shelving = _t.dig(book, "viewerShelving")

  -- Keep JSON null distinct from a missing field: only null confirms that
  -- it is safe to add the book to Currently Reading automatically.
  if shelving == nil then
    return {}, "Failed to read shelf from book page"
  end

  local shelved = shelving ~= json.util.null
  local shelf_name = nil

  if shelved then
    local ref = _t.dig(shelving, "__ref")
    shelf_name = ref and _t.dig(cache, ref, "shelf", "name")
    if type(shelf_name) ~= "string" or shelf_name == "" then
      return {}, "Failed to read shelf from book page"
    end
  end

  -- Goodreads' viewerShelving/shelf.name only ever reflects the 3 canonical
  -- exclusive shelves; Paused/Did Not Finish are tracked as non-exclusive
  -- "taggings" whose shape isn't confirmed from available data, so read-back
  -- for those two statuses isn't supported (write-only, via updateUserBook).
  -- Any other shelf comes back as `shelved` (with its name in `shelf`) but no
  -- status_id, so callers leave the book where it is.
  local status_id = nil
  if shelf_name == "to-read" then status_id = 1
  elseif shelf_name == "currently-reading" then status_id = 2
  elseif shelf_name == "read" then status_id = 3
  end

  local book_num_of_pages = tonumber(_t.dig(book, "details", "numPages")) or 0

  return {
    id = book_id,
    book_id = book_id,
    status_id = status_id,
    shelved = shelved,
    shelf = shelf_name,
    book_num_of_pages = book_num_of_pages,
    page_count = book_num_of_pages,
  }
end

function GoodreadsApi:findBookByIdentifiers(identifiers, user_id)
  if not identifiers then return nil end

  -- A Goodreads book id names an exact book page directly, so it's fetched
  -- straight from /book/show/<id> (same endpoint findUserBook polls status
  -- from) instead of going through a search -- same JSON-LD scrape findBooks
  -- uses for its own ISBN-redirect case.
  if identifiers.goodreads_id then
    local book_url = base_url .. "/book/show/" .. identifiers.goodreads_id
    local code, html = self:request(book_url, "GET")
    if code == 200 and html then
      local book_data = parse_ldjson_book(html)
      if book_data then
        return {
          book_id = identifiers.goodreads_id,
          title = book_data.title,
          contributions = { { author = { name = book_data.author } } },
          cached_image = { url = book_data.image },
          book_series = {},
          description = "",
        }
      end
    end
  end

  local isbn = identifiers.isbn_13 or identifiers.isbn_10
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

  local function send_update()
    return self:request(base_url .. "/shelf/add_to_shelf", "POST", {
      book_id = book_id,
      name = shelf,
      a = "",
    }, custom_headers)
  end

  local code, resp, response_headers = send_update()
  if code == 403 and response_headers and response_headers["x-refreshed-cookie"] then
    -- request() already retried with the refreshed cookie. If Goodreads still
    -- rejected that POST, fetch a CSRF token from the refreshed session before
    -- the final shelf-update attempt.
    local refreshed_csrf = self:refreshSession()
    if refreshed_csrf then
      custom_headers["X-CSRF-Token"] = refreshed_csrf
      logger.info("Goodreads: retrying shelf update with refreshed session CSRF token")
      code, resp = send_update()
    end
  end
  self.settings:debugLog("Goodreads: updateUserBook POST response code=" .. tostring(code))

  if code and code >= 200 and code < 300 then
    return self:findUserBook(book_id)
  end
  self.settings:debugWarn("Goodreads: updateUserBook failed - code=" .. tostring(code)
    .. " response_length=" .. tostring(type(resp) == "string" and #resp or 0))
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
  self.settings:debugWarn("Goodreads: updateProgress failed - code=" .. tostring(code)
    .. " response_length=" .. tostring(type(resp) == "string" and #resp or 0))
  return nil
end

-- Pushes KOReader's Book Status star rating (1-5, same scale as Goodreads,
-- no conversion needed). Goodreads still accepts this through its Rails AJAX
-- endpoint even though the review editor itself has moved to Next.js.
function GoodreadsApi:setRating(book_id, rating)
  local stars = math.floor(tonumber(rating) or 0)
  if stars < 1 or stars > 5 then
    self.settings:debugWarn("Goodreads: setRating - rating out of range: " .. tostring(rating))
    return nil
  end

  local csrf = self:refreshSession()
  if not csrf then
    logger.warn("Goodreads: Could not extract CSRF token for rating")
    return nil
  end

  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "*/*",
    ["Referer"] = base_url .. "/review/edit/" .. book_id,
    ["Origin"] = base_url,
  }

  local url = base_url .. "/review/rate/" .. book_id
    .. "?no_lightbox=true&queue=false&stars_click=true&rating=" .. stars .. "&ref=undefined"

  local code, resp = self:request(url, "POST", "", custom_headers)
  self.settings:debugLog("Goodreads: setRating POST response code=" .. tostring(code))

  if code and code >= 200 and code < 300 then
    return true
  end
  self.settings:debugWarn("Goodreads: setRating failed - code=" .. tostring(code) .. " resp=" .. tostring(resp))
  return nil
end

-- Sets the review body text. Older pages still use the Rails review form;
-- the current Next.js editor uses a Server Action and requires its existing
-- private fields and reading sessions to be echoed unchanged.
function GoodreadsApi:setReviewText(book_id, text)
  local csrf = self:refreshSession()

  local edit_url = base_url .. "/review/edit/" .. book_id
  local edit_code, edit_html = self:request(edit_url, "GET")
  if edit_code ~= 200 or not edit_html then
    self.settings:debugWarn("Goodreads: setReviewText - GET /review/edit failed, code=" .. tostring(edit_code))
    return nil
  end
  csrf = self:extract_csrf(edit_html) or csrf

  local update_path, update_method, form_stats = parse_review_update_target(edit_html, edit_url)
  if not update_path then
    local state = parse_next_review_state(edit_html)
    if state then
      return submit_next_review_text(self, book_id, text, edit_url, edit_html, state)
    end
    self.settings:debugWarn("Goodreads: setReviewText could not identify a review editor"
      .. " (forms=" .. tostring(form_stats.form_count)
      .. ", field_match=" .. tostring(form_stats.review_form)
      .. ", missing_action=" .. tostring(form_stats.missing_action)
      .. ", rejected_action=" .. tostring(form_stats.rejected_action) .. ")")
    return nil, "Could not locate the Goodreads review editor; review text was not saved"
  end

  if not csrf then
    logger.warn("Goodreads: Could not extract CSRF token for classic review text")
    return nil
  end
  local review = parse_review_edit(edit_html)
  if not review then
    self.settings:debugWarn("Goodreads: setReviewText - review edit page was empty")
    return nil, "Could not read the existing Goodreads review; review text was not saved"
  end

  local custom_headers = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Referer"] = edit_url,
    ["Origin"] = base_url,
  }
  local update_url = update_path:match("^https?://") and update_path or (base_url .. update_path)
  self.settings:debugLog("Goodreads: setReviewText POST target=" .. update_url
    .. " (from-page=" .. tostring(update_path ~= nil) .. ")")

  local code, resp = self:request(update_url, "POST", {
    _method = update_method,
    authenticity_token = csrf,
    ["review[review]"] = text,
    ["review[notes]"] = review.notes,
  }, custom_headers)
  self.settings:debugLog("Goodreads: setReviewText POST /review/update response code=" .. tostring(code))

  if code == 200 or code == 302 then
    return true
  end
  self.settings:debugWarn("Goodreads: setReviewText failed - code=" .. tostring(code) .. " resp=" .. tostring(resp))
  return nil, "Review text was not saved (HTTP " .. tostring(code) .. ")"
end

-- Stamps today as the book's "date read" via Goodreads' Reading Challenge
-- session mechanism -- there's no dedicated field to PATCH, a finished date
-- is really just a reading session whose start/end date are both today.
-- Three requests, mirroring what the "Update progress" -> "Finished" flow
-- does in the browser:
--   1. GET  /review/edit/{id}          -- scrape existing session count and
--                                          review/notes text (echoed back
--                                          unchanged in step 3 so this POST
--                                          doesn't blank them out)
--   2. GET  /reading_sessions/new      -- allocate a new session row id
--   3. POST /review/update/{id}        -- submit the review form with the
--                                          new session's start/end date set
--                                          to today
function GoodreadsApi:setDateFinished(book_id)
  local csrf = self:refreshSession()
  if not csrf then
    logger.warn("Goodreads: Could not extract CSRF token for date-finished")
    return nil
  end

  local edit_url = base_url .. "/review/edit/" .. book_id
  local edit_code, edit_html = self:request(edit_url, "GET")
  if edit_code ~= 200 or not edit_html then
    self.settings:debugWarn("Goodreads: setDateFinished - GET /review/edit failed, code=" .. tostring(edit_code))
    return nil
  end
  csrf = self:extract_csrf(edit_html) or csrf

  local review = parse_review_edit(edit_html)
  if not review then
    if self.settings then
      self.settings:debugWarn("Goodreads: setDateFinished - review edit page was empty")
    end
    return nil, "Could not read the existing Goodreads review; finish date was not saved"
  end

  if review.session_count and review.session_count > 0 then
    self.settings:debugLog("Goodreads: setDateFinished - a reading session already exists, skipping")
    return true
  end

  local session_url = base_url .. "/reading_sessions/new?book_id=" .. book_id
  local session_code, session_html = self:request(session_url, "GET", nil, {
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "*/*",
    ["Referer"] = edit_url,
  })
  if session_code ~= 200 or not session_html then
    self.settings:debugWarn("Goodreads: setDateFinished - GET /reading_sessions/new failed, code="
      .. tostring(session_code))
    return nil
  end

  local rowid = parse_new_session_rowid(session_html)
  if not rowid then
    self.settings:debugWarn("Goodreads: setDateFinished - could not find new session rowid")
    return nil
  end

  local today = os.date("*t")
  local field_prefix = "review[user_reading_sessions_attributes][" .. rowid .. "]"

  local custom_headers = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Referer"] = edit_url,
    ["Origin"] = base_url,
  }

  local update_path, update_method = parse_review_update_target(edit_html)
  if not update_path then return nil end
  local update_url = update_path:match("^https?://") and update_path or (base_url .. update_path)
  self.settings:debugLog("Goodreads: setDateFinished POST target=" .. update_url
    .. " (from-page=" .. tostring(update_path ~= nil) .. ")")

  local update_code, update_resp = self:request(update_url, "POST", {
    _method = update_method,
    authenticity_token = csrf,
    ["review[review]"] = review.review_text,
    ["review[notes]"] = review.notes,
    [field_prefix .. "[progress_type]"] = "percent",
    [field_prefix .. "[start][day]"] = today.day,
    [field_prefix .. "[start][month]"] = today.month,
    [field_prefix .. "[start][year]"] = today.year,
    [field_prefix .. "[end][day]"] = today.day,
    [field_prefix .. "[end][month]"] = today.month,
    [field_prefix .. "[end][year]"] = today.year,
  }, custom_headers)
  self.settings:debugLog("Goodreads: setDateFinished POST /review/update response code=" .. tostring(update_code))

  if update_code == 200 or update_code == 302 then
    return true
  end
  self.settings:debugWarn("Goodreads: setDateFinished failed - code=" .. tostring(update_code)
    .. " resp=" .. tostring(update_resp))
  return nil
end

-- Goodreads' "status update" (/user_status.json's `body` field) is a short
-- feed-post note attached to a progress update, not a book review, so this
-- is really just updateProgress with a note attached -- there's no richer
-- journal concept to map onto here.
function GoodreadsApi:createJournalEntry(data)
  local book_id = data.book_id
  if not book_id then return nil end

  return self:updateProgress(book_id, tonumber(data.progress) or 0, data.progress_type, data.text)
end

return GoodreadsApi
