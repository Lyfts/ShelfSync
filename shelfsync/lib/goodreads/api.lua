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
--    as one opaque blob (SETTING.SESSION_COOKIE), with no attempt to track
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
    cookie = self.settings:readSetting(SETTING.SESSION_COOKIE)
  end
  if not cookie or cookie == "" then cookie = config.cookie or "" end

  if cookie == "" then
    logger.warn("Goodreads: No session cookie found!")
  else
    logger.info("Goodreads: Using session cookie (length: " .. #cookie .. ")")
  end

  local headers = {
    ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64; rv:154.0) Gecko/20100101 Firefox/154.0",
    ["Cookie"] = cookie,
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Origin"] = "https://www.goodreads.com",
    ["DNT"] = "1",
  }
  if custom_headers then
    for k, v in pairs(custom_headers) do
      headers[k] = v
    end
  end
  return headers
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
    local sink = {}
    socketutil:set_timeout(timeout, maxtime)

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
    if headers["Cookie"] then
      logger.info("Goodreads: Final Cookie length: " .. #headers["Cookie"])
    end

    if method == "POST" and body then
      if not headers["Content-Type"] then
        headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
      headers["Content-Length"] = tostring(#body)
    end

    local request = {
      url = url,
      method = method or "GET",
      headers = headers,
      source = body and ltn12.source.string(body) or nil,
      sink = socketutil.table_sink(sink),
    }

    if method == "POST" then
      logger.info("Goodreads: POST URL: " .. url)
      logger.info("Goodreads: POST Body: " .. (body or "nil"))
    end

    local ok, code, _headers, _status = http.request(request)
    socketutil:reset_timeout()

    if type(code) ~= "number" and self.settings then
      self.settings:debugWarn("Goodreads: http.request to " .. url .. " failed - ok="
        .. tostring(ok) .. " code=" .. tostring(code))
    end

    local response_body = table.concat(sink)
    local header_str = ""
    if _headers then
      for k, v in pairs(_headers) do
        header_str = header_str .. k .. "=" .. tostring(v) .. "\n"
      end
    end
    return (code or "error") .. "|" .. header_str .. "|" .. response_body
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
    local code, header_str, response = string.match(content, "^([^|]*)|([^|]*)|(.*)")
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
  local code, html = self:request(search_url, "GET")

  if code ~= 200 or not html then
    logger.warn("Goodreads search failed. Code:", code)
    return {}, "Search failed with code " .. (code or "unknown")
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

function GoodreadsApi:updatePage(book_id, page, note)
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
  }

  local code, resp = self:request(base_url .. "/user_status.json", "POST", {
    ["user_status[book_id]"] = book_id,
    ["user_status[page]"] = page,
    ["user_status[body]"] = note or "",
  }, custom_headers)
  self.settings:debugLog("Goodreads: updatePage POST response code=" .. tostring(code))

  if code and code >= 200 and code < 300 then
    return self:findUserBook(book_id)
  end
  self.settings:debugWarn("Goodreads: updatePage failed - code=" .. tostring(code) .. " resp=" .. tostring(resp))
  return nil
end

-- Goodreads' "status update" (/user_status.json's `body` field) is a short
-- feed-post note attached to a page-progress update, not a book review, so
-- this is really just updatePage with a note attached -- there's no richer
-- journal concept to map onto here.
function GoodreadsApi:createJournalEntry(data)
  local book_id = data.book_id
  if not book_id then return nil end

  local page = tonumber(data.progress) or 0
  if data.progress_type ~= "pages" then
    local status = self:findUserBook(book_id)
    local total = status and tonumber(status.book_num_of_pages) or 0
    page = total > 0 and math.floor((page / 100) * total + 0.5) or 0
  else
    page = math.floor(page + 0.5)
  end

  return self:updatePage(book_id, page, data.entry)
end

return GoodreadsApi
