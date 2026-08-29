local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("shelfsync/lib/common/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local VERSION = require("shelfsync_version")

local SETTING = require("shelfsync/lib/common/constants/settings")
local FABLE = require("shelfsync/lib/fable/constants")

local base_url = "https://api.fable.co"
local identitytoolkit_url = "https://www.googleapis.com/identitytoolkit/v3/relyingparty"
local securetoken_url = "https://securetoken.googleapis.com/v1/token"

-- Fable's Android app authenticates against Firebase, and this is the
-- Firebase Web API key it ships with (confirmed via HAR capture: it's the
-- `key` query param on every identitytoolkit call the app makes). Firebase
-- API keys identify a Google Cloud project, not a caller -- they're baked
-- into every client of a Firebase app and aren't treated as secret by
-- Google (unlike the idToken/refreshToken/password a login exchanges for
-- one), so hardcoding it here is the same thing Fable's own client does.
local FIREBASE_API_KEY = "AIzaSyDEnLDTjMQ9v-XaQ7pk6pJxKrpVbX_rr6U"

local STATUS_BY_SYSTEM_TYPE = {}
for status_id, system_type in pairs(FABLE.SYSTEM_TYPE) do
  STATUS_BY_SYSTEM_TYPE[system_type] = status_id
end

local FableApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
}

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

-- Bare socket call shared by every request this file makes (login, token
-- refresh, and authenticated api.fable.co calls) -- callers are responsible
-- for their own Content-Type/body encoding since login/refresh use
-- Firebase's mixed json/form-urlencoded bodies while everything else here
-- is plain JSON.
local function raw_http(url, method, headers, body_string, timeout, maxtime)
  timeout = timeout or 10
  maxtime = maxtime or 15
  if body_string then
    headers["Content-Length"] = tostring(#body_string)
  end

  local sink = {}
  socketutil:set_timeout(timeout, maxtime)
  local _, code = http.request {
    url = url,
    method = method,
    headers = headers,
    source = body_string and ltn12.source.string(body_string) or nil,
    sink = socketutil.table_sink(sink),
  }
  socketutil:reset_timeout()

  return code, table.concat(sink)
end

-- Mirrors the token-presence check request() relies on, so callers can tell
-- whether a login has ever succeeded without making a network call.
function FableApi:hasCredential()
  local token = self.settings and self.settings:readSetting(SETTING.FABLE.REFRESH_TOKEN)
  return token ~= nil and token ~= ""
end

-- Warn (once per cooldown) that the stored credential is dead, mirroring
-- Goodreads/Hardcover's notifyAuthFailure.
function FableApi:notifyAuthFailure()
  local now = os.time()
  if self.last_auth_warning and now - self.last_auth_warning < 300 then
    return
  end
  self.last_auth_warning = now
  if self.on_error then
    self.on_error("Unauthorized")
  end
end

-- Logs in with email/password via Firebase's legacy Identity Toolkit REST
-- API (confirmed via HAR capture of the Fable Android app's own login
-- flow), then persists the resulting idToken/refreshToken pair. Runs in a
-- subprocess like every other network call here so it doesn't block the UI
-- thread when called from inside a Trapper:wrap() coroutine (see
-- fable/menu.lua's login dialog).
function FableApi:login(email, password)
  if not NetworkManager:isConnected() then
    return nil, "Network not connected"
  end

  local subprocess_fn = function()
    local body = json.encode({ email = email, password = password, returnSecureToken = true })
    local code, resp = raw_http(
      identitytoolkit_url .. "/verifyPassword?key=" .. FIREBASE_API_KEY,
      "POST",
      { ["Content-Type"] = "application/json" },
      body
    )
    return (code or "error") .. ":" .. resp
  end

  local completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
  if not (completed and content) then
    return nil, "Login request failed"
  end

  local code, resp = content:match("^([^:]*):(.*)")
  local code_num = tonumber(code)

  if code_num ~= 200 then
    local ok, data = pcall(json.decode, resp, json.decode.simple)
    local message = ok and _t.dig(data, "error", "message")
    logger.warn("Fable: login failed with HTTP " .. tostring(code_num))
    return nil, message or ("Login failed (HTTP " .. tostring(code_num) .. ")")
  end

  local ok, data = pcall(json.decode, resp, json.decode.simple)
  if not ok or not data or not data.idToken or not data.refreshToken then
    return nil, "Login response missing tokens"
  end

  if self.settings then
    self.settings:updateSetting(SETTING.FABLE.EMAIL, data.email or email)
    self.settings:updateSetting(SETTING.FABLE.ID_TOKEN, data.idToken)
    self.settings:updateSetting(SETTING.FABLE.REFRESH_TOKEN, data.refreshToken)
    self.settings:updateSetting(SETTING.FABLE.TOKEN_EXPIRES_AT, os.time() + (tonumber(data.expiresIn) or 3600))
  end

  return true
end

-- Authenticated request against api.fable.co. Refreshes the idToken first
-- if it's at or past expiry -- confirmed via HAR that idTokens are only
-- valid for 3600s, but the refresh call itself was never exercised in the
-- capture (the session never lived long enough), so this follows Firebase's
-- publicly documented Secure Token REST API rather than an observed
-- request/response pair.
--
-- Since a forked subprocess can't write back into this instance's
-- `self.settings`, a token refreshed here is smuggled back to the parent
-- process as a pseudo-header, the same trick Goodreads uses for its
-- cookie-refresher (see goodreads/api.lua's request()) -- and for the same
-- reason: the header block's length is prefixed rather than delimited,
-- since a refreshed idToken/refreshToken could in principle itself contain
-- "|" or "=".
function FableApi:request(path, method, body)
  if not NetworkManager:isConnected() or not self.enabled then
    return nil, "Network not connected"
  end

  local subprocess_fn = function()
    local timeout, maxtime = 10, 15

    local id_token = (self.settings and self.settings:readSetting(SETTING.FABLE.ID_TOKEN)) or ""
    local refresh_token = (self.settings and self.settings:readSetting(SETTING.FABLE.REFRESH_TOKEN)) or ""
    local expires_at = (self.settings and self.settings:readSetting(SETTING.FABLE.TOKEN_EXPIRES_AT)) or 0
    local refreshed_id_token, refreshed_refresh_token, refreshed_expires_at

    if refresh_token ~= "" and os.time() >= (expires_at - 60) then
      local refresh_body = "grant_type=refresh_token&refresh_token=" .. urlencode(refresh_token)
      local refresh_code, refresh_resp = raw_http(
        securetoken_url .. "?key=" .. FIREBASE_API_KEY,
        "POST",
        { ["Content-Type"] = "application/x-www-form-urlencoded" },
        refresh_body,
        timeout,
        maxtime
      )
      if refresh_code == 200 then
        local ok, data = pcall(json.decode, refresh_resp, json.decode.simple)
        if ok and data and data.id_token and data.refresh_token then
          id_token = data.id_token
          refresh_token = data.refresh_token
          refreshed_id_token = id_token
          refreshed_refresh_token = refresh_token
          refreshed_expires_at = os.time() + (tonumber(data.expires_in) or 3600)
        end
      end
    end

    local encoded_body = body and json.encode(body)
    local headers = {
      ["Authorization"] = "JWT " .. id_token,
      ["Content-Type"] = "application/json",
      ["User-Agent"] = T("shelfsync.koplugin/%1 (https://github.com/Lyfts/ShelfSync)",
        table.concat(VERSION, ".")),
    }

    local code, response_body = raw_http(base_url .. path, method or "GET", headers, encoded_body, timeout, maxtime)

    local header_str = ""
    if refreshed_id_token then
      header_str = header_str
        .. "x-refreshed-id-token=" .. refreshed_id_token .. "\n"
        .. "x-refreshed-refresh-token=" .. refreshed_refresh_token .. "\n"
        .. "x-refreshed-expires-at=" .. tostring(refreshed_expires_at) .. "\n"
    end

    return (code or "error") .. "|" .. #header_str .. "|" .. header_str .. response_body
  end

  local completed, content
  for attempt = 1, 2 do
    completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
    if completed then break end
  end

  if not (completed and content) then
    return nil, "Request failed"
  end

  local code, header_len, rest = string.match(content, "^([^|]*)|(%d+)|(.*)")
  local code_num = tonumber(code)
  header_len = tonumber(header_len)
  local header_str = rest:sub(1, header_len)
  local response_body = rest:sub(header_len + 1)

  if self.settings then
    for k, v in header_str:gmatch("([%w%-]+)=([^\n]*)\n") do
      if k == "x-refreshed-id-token" then
        self.settings:updateSetting(SETTING.FABLE.ID_TOKEN, v)
      elseif k == "x-refreshed-refresh-token" then
        self.settings:updateSetting(SETTING.FABLE.REFRESH_TOKEN, v)
      elseif k == "x-refreshed-expires-at" then
        self.settings:updateSetting(SETTING.FABLE.TOKEN_EXPIRES_AT, tonumber(v))
      end
    end
  end

  if code_num == 401 or code_num == 403 then
    self:notifyAuthFailure()
    return nil, "Unauthorized"
  end

  local data
  if response_body ~= "" then
    local ok, decoded = pcall(json.decode, response_body, json.decode.simple)
    if ok then data = decoded end
  end

  if self.settings and code_num and (code_num < 200 or code_num >= 300) then
    self.settings:debugWarn("Fable: " .. (method or "GET") .. " " .. path .. " returned "
      .. tostring(code_num) .. " body=" .. tostring(response_body))
  end

  return code_num, data
end

function FableApi:me()
  local code, data = self:request("/api/settings/profile/", "GET")
  if code == 200 and data then
    return { id = data.id }
  end
  if self.settings then
    self.settings:debugWarn("Fable: me() failed - code=" .. tostring(code))
  end
  return {}
end

local function normalize_book(book)
  local authors = {}
  for _, author in ipairs(book.authors or {}) do
    table.insert(authors, { author = { name = author.name } })
  end
  if #authors == 0 then
    authors = { { author = { name = "Unknown Author" } } }
  end

  return {
    id = book.id,
    book_id = book.id,
    title = book.title,
    contributions = authors,
    cached_image = { url = book.cover_image },
    book_series = {},
    description = book.description or "",
    isbn = book.isbn or book.display_isbn,
    -- Every book-level response observed in the capture (search results
    -- and the book-detail endpoint alike) carries page_count: null -- only
    -- the editions/ endpoint (see findEditionPageCount below) ever has a
    -- real value, so this is nil in practice, not a bug.
    page_count = book.page_count,
  }
end

function FableApi:findBooks(title, author, _user_id)
  local query = title or ""
  if author and author ~= "" then query = query .. " " .. author end
  if query:match("^%s*$") then
    return {}
  end

  local path = "/api/books/search/?auto=" .. urlencode(query) .. "&include=out_of_catalog&type=book&limit=20&offset=0"
  local code, data = self:request(path, "GET")
  if code ~= 200 or not data then
    return {}, "Search failed"
  end

  local books = _t.dig(data, "response", "books") or {}
  return _t.map(books, normalize_book)
end

function FableApi:findBookByIdentifiers(identifiers, user_id)
  local isbn = identifiers and (identifiers.isbn_13 or identifiers.isbn_10)
  if not isbn then
    return nil
  end

  local results = self:findBooks(isbn, nil, user_id)
  for _, book in ipairs(results) do
    if book.isbn == isbn then
      return book
    end
  end
  return results[1]
end

-- The book-detail endpoint doubles as the per-viewer status lookup: its
-- embedded `response.status` field (confirmed live: nil before shelving,
-- "current_reading"/"finished" after) reflects the caller's own shelving
-- state directly, so no separate book_lists lookup is needed just to read
-- status. Deliberately doesn't resolve a page count here (that needs a
-- second, paginated editions/ call -- see findEditionPageCount) since
-- findUserBook is called far more often than a book is first linked.
function FableApi:findUserBook(book_id, _user_id)
  if not book_id then
    return {}
  end

  local code, data = self:request("/api/books/" .. book_id, "GET")
  if code ~= 200 or not data then
    return {}, "Failed to fetch book"
  end

  local status = _t.dig(data, "response", "status")

  return {
    id = book_id,
    book_id = book_id,
    status_id = STATUS_BY_SYSTEM_TYPE[status],
  }
end

-- Fable's own book/search-result page_count is always null (see
-- normalize_book above) -- only this editions/ endpoint carries a real
-- count, and a book can have dozens of editions across formats/languages
-- with different counts. Prefers, in order: an edition whose display_isbn
-- matches the linked document's own ISBN (when known), then the edition
-- Fable marks `is_current_book` (the one its book/search ids actually
-- refer to), then the first edition with a non-null count -- this last
-- fallback is a heuristic, not a documented "best edition" concept on
-- Fable's side.
function FableApi:findEditionPageCount(book_id, isbn)
  local code, data = self:request("/api/books/" .. book_id .. "/editions/", "GET")
  if code ~= 200 or not data or not data.results then
    return nil
  end

  local editions = data.results

  if isbn then
    for _, edition in ipairs(editions) do
      if edition.display_isbn == isbn and edition.page_count and edition.page_count > 0 then
        return edition.page_count
      end
    end
  end

  for _, edition in ipairs(editions) do
    if edition.is_current_book and edition.page_count and edition.page_count > 0 then
      return edition.page_count
    end
  end

  for _, edition in ipairs(editions) do
    if edition.page_count and edition.page_count > 0 then
      return edition.page_count
    end
  end

  return nil
end

-- Fable's book_lists ids (unlike its book_lists `system_type` slugs, which
-- are fixed -- see fable/constants.lua) are randomly generated per account,
-- not global constants, so they have to be looked up before the first
-- shelving write. Cached on the api instance, keyed by user_id, since
-- nothing observed ever changes an account's own system list ids after
-- creation.
function FableApi:_systemListIds(user_id)
  if self._system_lists and self._system_lists.user_id == user_id then
    return self._system_lists.by_type
  end

  local code, data = self:request(
    "/api/v2/users/" .. user_id .. "/book_lists?limit=20&offset=0&media_type=book", "GET"
  )
  if code ~= 200 or not data or not data.results then
    if self.settings then
      self.settings:debugWarn("Fable: _systemListIds failed - code=" .. tostring(code)
        .. " has_data=" .. tostring(data ~= nil) .. " has_results=" .. tostring(data and data.results ~= nil))
    end
    return nil
  end

  local by_type = {}
  for _, list in ipairs(data.results) do
    if list.type == "system" and list.system_type then
      by_type[list.system_type] = list.id
    end
  end

  if self.settings then
    local types = {}
    for system_type in pairs(by_type) do
      table.insert(types, system_type)
    end
    self.settings:debugLog("Fable: _systemListIds resolved types=" .. table.concat(types, ","))
  end

  self._system_lists = { user_id = user_id, by_type = by_type }
  return by_type
end

-- Shelves a book on exactly one of Fable's 4 system lists (see
-- fable/constants.lua's SYSTEM_TYPE -- there is no "paused" list to worry
-- about), excluding it from the other 3 in the same call. Confirmed via
-- HAR: no CSRF token is needed for this or any other write, the JWT bearer
-- header is sufficient.
function FableApi:updateUserBook(book_id, status_id)
  local user_id = self.settings and self.settings:readSetting(SETTING.USER_ID)
  local target_type = FABLE.SYSTEM_TYPE[status_id]
  if not user_id or not target_type then
    if self.settings then
      self.settings:debugWarn("Fable: updateUserBook aborted - user_id="
        .. tostring(user_id) .. " target_type=" .. tostring(target_type))
    end
    return nil
  end

  local by_type = self:_systemListIds(user_id)
  if not by_type or not by_type[target_type] then
    if self.settings then
      self.settings:debugWarn("Fable: updateUserBook aborted - system list for '"
        .. target_type .. "' not found (by_type=" .. tostring(by_type) .. ")")
    end
    return nil
  end

  local exclude_from = {}
  for _, other_status in pairs(FABLE.STATUS) do
    local other_type = FABLE.SYSTEM_TYPE[other_status]
    if other_type and other_type ~= target_type and by_type[other_type] then
      table.insert(exclude_from, by_type[other_type])
    end
  end

  local code = self:request(
    "/api/v2/users/" .. user_id .. "/book_lists/book",
    "POST",
    {
      type = "multiselect",
      book_id = book_id,
      book_list_ids = { by_type[target_type] },
      exclude_from = exclude_from,
    }
  )

  if code and code >= 200 and code < 300 then
    return self:findUserBook(book_id, user_id)
  end
  return nil
end

-- Confirmed via HAR: unlike updateUserBook, removal doesn't need the
-- per-account system list ids resolved first -- the RemoveFromLibrary
-- request type takes only the book_id and a remove_from_all_lists flag, and
-- Fable's API strips the book off every list (system and custom alike)
-- itself.
function FableApi:removeRead(book_id)
  local user_id = self.settings and self.settings:readSetting(SETTING.USER_ID)
  if not user_id then
    return nil
  end

  local code = self:request(
    "/api/v2/users/" .. user_id .. "/book_lists/book",
    "POST",
    {
      type = "co.fable.data.BookListRequest.RemoveFromLibrary",
      book_id = book_id,
      remove_from_all_lists = true,
    }
  )

  if code and code >= 200 and code < 300 then
    return { id = book_id }
  end
  return nil
end

-- Confirmed via HAR (percentage mode only -- the capture never exercised
-- page-based tracking): the POST body is
-- {current_percentage, status="reading", social_accounts={}, selected_mode}.
-- The page-mode body below (current_page instead of current_percentage) is
-- inferred by symmetry, not independently confirmed against a capture.
--
-- Re-fetches the book afterwards for an authoritative status_id rather than
-- trying to map this endpoint's own response `status` field (which uses a
-- reading-session vocabulary like "reading", not the shelving vocabulary
-- STATUS_BY_SYSTEM_TYPE expects) -- same pattern as Goodreads' updateProgress.
function FableApi:updateProgress(book_id, value, update_type)
  -- Fable rejects an empty social_accounts encoded as a JSON object ("{}")
  -- with a 400 -- it must be an empty array ("[]"). An empty Lua table is
  -- ambiguous to the JSON encoder, so it has to be marked explicitly.
  local body = { status = "reading", social_accounts = json.util.InitArray({}) }
  if update_type == "pages" then
    body.current_page = math.floor(value)
    body.selected_mode = "page"
  else
    body.current_percentage = math.floor(value)
    body.selected_mode = "percentage"
  end

  local code = self:request("/api/books/" .. book_id .. "/reading_progress", "POST", body)
  if code ~= 200 and code ~= 201 then
    return nil
  end

  return self:findUserBook(book_id)
end

-- Fable's reading_progress endpoint (unlike Goodreads' /user_status.json)
-- carries no note/body field in any captured request -- there's no
-- confirmed way to persist journal text to Fable at all, so `data.entry` is
-- silently dropped and only the progress value itself is pushed.
function FableApi:createJournalEntry(data)
  if not data or not data.book_id then
    return nil
  end
  return self:updateProgress(data.book_id, tonumber(data.progress) or 0, data.progress_type)
end

return FableApi
