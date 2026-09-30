local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("shelfsync/lib/common/table_util")
local CryptoUtil = require("shelfsync/lib/common/crypto_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local VERSION = require("shelfsync_version")
local SETTING = require("shelfsync/lib/common/constants/settings")
local PAGEBOUND = require("shelfsync/lib/pagebound/constants")

local IDENTITY_TOOLKIT_URL = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword"
local SECURE_TOKEN_URL = "https://securetoken.googleapis.com/v1/token"
local PAGEBOUND_AUTH_TIMEOUT = 75
local PAGEBOUND_AUTH_TOTAL_TIMEOUT = 90

local PageboundApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
}

local function urlencode(str)
  if str then
    str = tostring(str):gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
      return ("%%%02X"):format(string.byte(c))
    end)
    str = str:gsub(" ", "+")
  end
  return str or ""
end

local function raw_http(url, method, headers, body_string, timeout, maxtime)
  timeout = timeout or 15
  maxtime = maxtime or 25
  headers = headers or {}
  if body_string then
    headers["Content-Length"] = tostring(#body_string)
  end

  local sink = {}
  socketutil:set_timeout(timeout, maxtime)
  local ok, _, code = pcall(http.request, {
    url = url,
    method = method,
    headers = headers,
    source = body_string and ltn12.source.string(body_string) or nil,
    sink = socketutil.table_sink(sink),
  })
  socketutil:reset_timeout()

  if not ok then
    return nil, tostring(_)
  end
  return code, table.concat(sink)
end

local function decode_json(text)
  if not text or text == "" then return nil end
  local ok, data = pcall(json.decode, text, json.decode.simple)
  if ok then return data end
  return nil
end

local function pagebound_date()
  local month, day, year = os.date("%m/%d/%Y"):match("^(%d+)/(%d+)/(%d+)$")
  return ("%d/%d/%s"):format(tonumber(month), tonumber(day), year)
end

local function form_date(value)
  if not value or value == "" then return nil end
  local year, month, day = tostring(value):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if year then
    return ("%d/%d/%s"):format(tonumber(month), tonumber(day), year)
  end
  return tostring(value)
end

local function error_message(body, fallback)
  local data = decode_json(body)
  local message = _t.dig(data, "error", "message") or _t.dig(data, "message")
  if message and message ~= "" then return tostring(message) end
  return fallback
end

local function request_failure(code)
  if type(code) == "number" then return "HTTP " .. tostring(code) end
  return tostring(code or "no response")
end

local function stored_password(settings)
  if not settings then return nil end
  local encrypted = settings:readSetting(SETTING.PAGEBOUND.PASSWORD_ENC)
  if encrypted and encrypted ~= "" then
    return CryptoUtil.decryptSecret(encrypted)
  end
  local plain = settings:readSetting(SETTING.PAGEBOUND.PASSWORD_PLAIN)
  if plain and plain ~= "" then return plain end
  return nil
end

local function firebase_sign_in(email, password)
  local body = json.encode({
    clientType = "CLIENT_TYPE_WEB",
    email = email,
    password = password,
    returnSecureToken = true,
  })
  local code, response = raw_http(
    IDENTITY_TOOLKIT_URL .. "?key=" .. PAGEBOUND.FIREBASE_API_KEY,
    "POST",
    { ["Content-Type"] = "application/json" },
    body
  )
  local data = decode_json(response)
  if tonumber(code) ~= 200 or not data or not data.idToken or not data.refreshToken then
    return nil, error_message(response, "Firebase sign-in failed (" .. request_failure(code) .. ")")
  end
  return {
    id_token = data.idToken,
    refresh_token = data.refreshToken,
    expires_at = os.time() + (tonumber(data.expiresIn) or 3600),
    email = data.email or email,
  }
end

local function firebase_refresh(refresh_token)
  if not refresh_token or refresh_token == "" then
    return nil, "Missing Firebase refresh token"
  end

  local body = "grant_type=refresh_token&refresh_token=" .. urlencode(refresh_token)
  local code, response = raw_http(
    SECURE_TOKEN_URL .. "?key=" .. PAGEBOUND.FIREBASE_API_KEY,
    "POST",
    { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body
  )
  local data = decode_json(response)
  if tonumber(code) ~= 200 or not data or not data.id_token or not data.refresh_token then
    return nil, error_message(response, "Firebase session refresh failed")
  end
  return {
    id_token = data.id_token,
    refresh_token = data.refresh_token,
    expires_at = os.time() + (tonumber(data.expires_in) or 3600),
  }
end

local function exchange_firebase_token(id_token)
  local code, response = raw_http(
    PAGEBOUND.API_URL .. "/api/v1/auth/firebase_auth",
    "POST",
    {
      ["Content-Type"] = "application/json",
      -- The captured web login sends the literal null bearer before it has
      -- received Pagebound's own API token. The Firebase id token is in the
      -- JSON body and is what the endpoint exchanges.
      ["Authorization"] = "Bearer null",
    },
    json.encode({ id_token = id_token }),
    PAGEBOUND_AUTH_TIMEOUT,
    PAGEBOUND_AUTH_TOTAL_TIMEOUT
  )
  local data = decode_json(response)
  if tonumber(code) ~= 200 or not data or not data.token then
    return nil, error_message(response, "Pagebound token exchange failed (" .. request_failure(code) .. ")")
  end
  return {
    api_token = data.token,
    user_id = _t.dig(data, "user", "id"),
    email = _t.dig(data, "user", "email"),
  }
end

local function persist_session(settings, session)
  if not settings or not session then return end
  if session.id_token then settings:updateSetting(SETTING.PAGEBOUND.FIREBASE_ID_TOKEN, session.id_token) end
  if session.refresh_token then settings:updateSetting(SETTING.PAGEBOUND.REFRESH_TOKEN, session.refresh_token) end
  if session.expires_at then settings:updateSetting(SETTING.PAGEBOUND.TOKEN_EXPIRES_AT, session.expires_at) end
  if session.api_token then settings:updateSetting(SETTING.PAGEBOUND.API_TOKEN, session.api_token) end
  if session.user_id then settings:updateSetting(SETTING.USER_ID, session.user_id) end
  if session.email then settings:updateSetting(SETTING.PAGEBOUND.EMAIL, session.email) end
end

function PageboundApi:hasCredential()
  if not self.settings then return false end
  local api_token = self.settings:readSetting(SETTING.PAGEBOUND.API_TOKEN)
  local refresh_token = self.settings:readSetting(SETTING.PAGEBOUND.REFRESH_TOKEN)
  local id_token = self.settings:readSetting(SETTING.PAGEBOUND.FIREBASE_ID_TOKEN)
  return (api_token and api_token ~= "")
    or (refresh_token and refresh_token ~= "")
    or (id_token and id_token ~= "") or false
end

function PageboundApi:notifyAuthFailure()
  local now = os.time()
  if self.last_auth_warning and now - self.last_auth_warning < 300 then return end
  self.last_auth_warning = now
  if self.on_error then self.on_error("Unauthorized") end
end

function PageboundApi:login(email, password, on_status)
  if not NetworkManager:isConnected() then
    return nil, "Network not connected"
  end
  if not email or email == "" or not password or password == "" then
    return nil, "Email and password are required"
  end

  local function run_login_stage(stage, subprocess_fn)
    local completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
    if not (completed and content) then
      return nil, "Login did not complete during " .. stage .. " (cancelled or interrupted)"
    end

    local result, payload = content:match("^([^|]+)|(.*)$")
    if result ~= "ok" then
      logger.warn("Pagebound: " .. stage .. " failed")
      return nil, payload or (stage .. " failed")
    end

    local data = decode_json(payload)
    if not data then
      return nil, "Invalid response during " .. stage
    end
    return data
  end

  local firebase, firebase_error = run_login_stage("Firebase sign-in", function()
    local firebase, firebase_error = firebase_sign_in(email, password)
    if not firebase then
      return "error|" .. tostring(firebase_error)
    end
    return "ok|" .. json.encode(firebase)
  end)
  if not firebase then return nil, firebase_error end

  if on_status then on_status("pagebound_exchange") end
  local pagebound, exchange_error = run_login_stage("Pagebound token exchange", function()
    local pagebound, exchange_error = exchange_firebase_token(firebase.id_token)
    if not pagebound then
      return "error|" .. tostring(exchange_error)
    end
    return "ok|" .. json.encode(pagebound)
  end)
  if not pagebound then return nil, exchange_error end

  firebase.api_token = pagebound.api_token
  firebase.user_id = pagebound.user_id
  firebase.email = pagebound.email or firebase.email
  if not firebase.api_token or not firebase.refresh_token then
    return nil, "Login response missing tokens"
  end

  persist_session(self.settings, firebase)
  if self.settings then
    local encrypted = CryptoUtil.encryptSecret(password)
    if encrypted then
      self.settings:updateSetting(SETTING.PAGEBOUND.PASSWORD_ENC, encrypted)
      self.settings:updateSetting(SETTING.PAGEBOUND.PASSWORD_PLAIN, "")
    else
      self.settings:updateSetting(SETTING.PAGEBOUND.PASSWORD_ENC, "")
      self.settings:updateSetting(SETTING.PAGEBOUND.PASSWORD_PLAIN, password)
    end
  end
  return true
end

local function response_from_subprocess(content)
  if not content then return nil end
  local code, meta_len, rest = content:match("^([^|]*)|(%d+)|(.*)")
  if not code then return nil end
  meta_len = tonumber(meta_len) or 0
  local meta = decode_json(rest:sub(1, meta_len)) or {}
  local body = rest:sub(meta_len + 1)
  return tonumber(code), meta, body
end

function PageboundApi:request(path, method, body)
  if not NetworkManager:isConnected() or not self.enabled then
    return nil, "Network not connected"
  end

  local subprocess_fn = function()
    local timeout, maxtime = 15, 30
    local id_token = (self.settings and self.settings:readSetting(SETTING.PAGEBOUND.FIREBASE_ID_TOKEN)) or ""
    local refresh_token = (self.settings and self.settings:readSetting(SETTING.PAGEBOUND.REFRESH_TOKEN)) or ""
    local api_token = (self.settings and self.settings:readSetting(SETTING.PAGEBOUND.API_TOKEN)) or ""
    local expires_at = tonumber(self.settings and self.settings:readSetting(SETTING.PAGEBOUND.TOKEN_EXPIRES_AT)) or 0
    local email = (self.settings and self.settings:readSetting(SETTING.PAGEBOUND.EMAIL)) or ""
    local user_id = self.settings and self.settings:readSetting(SETTING.USER_ID)
    local session_changed = {}

    local function apply_firebase(session)
      id_token = session.id_token or id_token
      refresh_token = session.refresh_token or refresh_token
      expires_at = session.expires_at or expires_at
      session_changed.id_token = id_token
      session_changed.refresh_token = refresh_token
      session_changed.expires_at = expires_at
      if session.email then
        email = session.email
        session_changed.email = email
      end
    end

    local function sign_in_again()
      local password = stored_password(self.settings)
      if email == "" or not password then
        return nil, "Pagebound login expired; log in again from the Pagebound menu"
      end
      local session, err = firebase_sign_in(email, password)
      if not session then return nil, err end
      apply_firebase(session)
      return true
    end

    local function refresh_firebase()
      if refresh_token ~= "" then
        local session = firebase_refresh(refresh_token)
        if session then
          apply_firebase(session)
          return true
        end
      end
      if id_token ~= "" and expires_at > os.time() + 60 then
        return true
      end
      return sign_in_again()
    end

    local function exchange()
      if id_token == "" then
        local ok, err = refresh_firebase()
        if not ok then return nil, err end
      end
      local session, err = exchange_firebase_token(id_token)
      if not session then return nil, err end
      api_token = session.api_token
      session_changed.api_token = api_token
      if session.user_id then
        user_id = session.user_id
        session_changed.user_id = user_id
      end
      if session.email then
        email = session.email
        session_changed.email = email
      end
      return true
    end

    local function ensure_session(force)
      local token_expiring = id_token == "" or expires_at <= os.time() + 60
      if force or token_expiring then
        local ok, err = refresh_firebase()
        if not ok then return nil, err end
      end
      if force or api_token == "" or token_expiring then
        return exchange()
      end
      return true
    end

    local function send_request()
      local request_headers = {
        ["Authorization"] = "Bearer " .. api_token,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/plain, */*",
        ["User-Agent"] = T("ShelfSync/%1 (https://github.com/Lyfts/ShelfSync)", table.concat(VERSION, ".")),
      }
      return raw_http(
        PAGEBOUND.API_URL .. path,
        method or "GET",
        request_headers,
        body and json.encode(body) or nil,
        timeout,
        maxtime
      )
    end

    local ok, auth_error = ensure_session(false)
    local code, response_body
    if ok then
      code, response_body = send_request()
      if (tonumber(code) == 401 or tonumber(code) == 403) then
        local renewed = ensure_session(true)
        if renewed then
          code, response_body = send_request()
        end
      end
    else
      code = 401
      response_body = json.encode({ error = { message = auth_error or "Unauthorized" } })
    end

    local metadata = json.encode(session_changed)
    return tostring(code or "error") .. "|" .. #metadata .. "|" .. metadata .. (response_body or "")
  end

  local completed, content
  for _attempt = 1, 2 do
    completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
    if completed then break end
  end
  if not (completed and content) then
    return nil, "Request failed"
  end

  local code, session, response_body = response_from_subprocess(content)
  if not code then return nil, "Invalid response from Pagebound" end
  persist_session(self.settings, session)

  if code == 401 or code == 403 then
    self:notifyAuthFailure()
    return nil, "Unauthorized"
  end

  if code < 200 or code >= 300 then
    if self.settings then
      self.settings:debugWarn("Pagebound: " .. (method or "GET") .. " " .. path .. " returned " .. tostring(code))
    end
  end

  return code, decode_json(response_body)
end

function PageboundApi:me()
  local id = self.settings and self.settings:readSetting(SETTING.USER_ID)
  return id and { id = id } or {}
end

local function normalize_book(book)
  if not book or not book.id then return nil end
  local author = book.author_name or book.author or "Unknown Author"
  local page_count = tonumber(book.page_count)
  return {
    id = book.id,
    book_id = tostring(book.id),
    book_uuid = book.uuid,
    title = book.title or "Untitled",
    contributions = { { author = { name = author } } },
    cached_image = { url = book.image_url or book.image_url_medium or book.image_url_small },
    description = book.description or "",
    pages = page_count,
    page_count = page_count,
    isbn = book.isbn,
  }
end

local function typesense_query_url(query)
  local params = {
    "q=" .. urlencode(query),
    "query_by=title%2Cauthor_name",
    "limit=6",
    "num_typos=2",
    "split_join_tokens=always",
    "typo_tokens_threshold=6",
  }
  return PAGEBOUND.TYPESENSE_URL .. "/collections/books/documents/search?" .. table.concat(params, "&")
end

function PageboundApi:findBooks(title, author, _user_id)
  local query = title or ""
  if author and author ~= "" then query = query .. " " .. author end
  if query:match("^%s*$") then return {} end
  if not NetworkManager:isConnected() then return {}, "Network not connected" end

  local url = typesense_query_url(query)
  local subprocess_fn = function()
    local code, response = raw_http(url, "GET", {
      ["X-TYPESENSE-API-KEY"] = PAGEBOUND.TYPESENSE_API_KEY,
      ["Accept"] = "application/json",
    })
    return tostring(code or "error") .. "\n" .. (response or "")
  end

  local completed, content
  for _attempt = 1, 2 do
    completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
    if completed then break end
  end
  if not (completed and content) then return {}, "Search request failed" end

  local code, response = content:match("^([^\n]*)\n(.*)$")
  local data = decode_json(response)
  if tonumber(code) ~= 200 or not data or type(data.hits) ~= "table" then
    if self.settings then self.settings:debugWarn("Pagebound: book search returned " .. tostring(code)) end
    return {}, "Search failed"
  end

  local books = {}
  for _, hit in ipairs(data.hits) do
    local book = normalize_book(hit.document)
    if book then table.insert(books, book) end
  end
  return books
end

local function linked_book_uuid(self, book_id, candidate_uuid)
  if candidate_uuid and candidate_uuid ~= "" then
    return candidate_uuid
  end

  local settings = self.settings
  local filename = settings and settings.getFilePath and settings:getFilePath()
  if filename and settings.readBookSetting then
    local linked_id = settings:readBookSetting(filename, "book_id")
    if tostring(linked_id or "") == tostring(book_id or "") then
      local uuid = settings:readBookSetting(filename, "book_uuid")
      if uuid and uuid ~= "" then return uuid end
    end
  end

  return nil
end

function PageboundApi:getBook(book_id, book_uuid)
  if not book_id then return nil end
  local resource_uuid = linked_book_uuid(self, book_id, book_uuid)
  if not resource_uuid then
    return nil, "Missing Pagebound book UUID; unlink and link the book again"
  end
  local code, data = self:request("/api/v1/books/" .. urlencode(resource_uuid), "GET")
  if code ~= 200 or not data or not data.book then
    return nil, "Failed to fetch Pagebound book"
  end
  return data.book
end

function PageboundApi:findBookByIdentifiers(_identifiers, _user_id)
  return nil
end

local function current_reading_instance(user_book)
  if user_book.current_reading_instance and user_book.current_reading_instance.id
    and user_book.current_reading_instance.current ~= false then
    return user_book.current_reading_instance
  end
  for _, read in ipairs(user_book.reading_instances or {}) do
    if read.current and read.id then return read end
  end
  return nil
end

function PageboundApi:findUserBook(book_id, _user_id, book_uuid)
  if not book_id then return {} end
  local book, err = self:getBook(book_id, book_uuid)
  if not book then return {}, err end

  local user_book = book.user_book
  local page_count = tonumber(book.page_count)
  if not user_book then
    return {
      book_id = tostring(book.id or book_id),
      title = book.title,
      page_count = page_count,
      total_page_count = page_count,
    }
  end

  local read = current_reading_instance(user_book)
  local normalized_current_read
  local reads = {}
  if read then
    local normalized_read = {}
    for key, value in pairs(read) do normalized_read[key] = value end
    normalized_read.user_book_id = tonumber(normalized_read.user_book_id) or tonumber(user_book.id)
      or normalized_read.user_book_id or user_book.id
    normalized_read.started_reading_at = form_date(read.started_reading_at_date or read.started_reading_at)
    normalized_read.finished_reading_at = form_date(read.finished_reading_at_date or read.finished_reading_at)
    normalized_current_read = normalized_read
    reads[1] = normalized_read
  end

  local total_page_count = tonumber(user_book.total_page_count)
    or (normalized_current_read and tonumber(normalized_current_read.total_page_count)) or page_count

  return {
    id = user_book.uuid or tostring(user_book.id),
    user_book_id = tonumber(user_book.id) or user_book.id,
    user_book_uuid = user_book.uuid,
    book_id = tostring(user_book.book_id or book.id or book_id),
    book_uuid = book.uuid,
    title = user_book.title or book.title,
    status = user_book.status,
    status_id = PAGEBOUND.STATUS_BY_SYSTEM_STATUS[user_book.status],
    progress = tonumber(user_book.progress) or 0,
    progress_method = (normalized_current_read and normalized_current_read.progress_method) or user_book.progress_method,
    current_page = tonumber(user_book.current_page),
    current_minute = tonumber(user_book.current_minute),
    total_page_count = total_page_count,
    total_minutes = tonumber(user_book.total_minutes),
    page_count = total_page_count or page_count,
    owned = user_book.owned == true,
    muted = user_book.muted == true,
    date_added = user_book.date_added,
    started_reading_at = (normalized_current_read and normalized_current_read.started_reading_at) or user_book.started_reading_at,
    finished_reading_at = (normalized_current_read and normalized_current_read.finished_reading_at) or user_book.finished_reading_at,
    challenge_year = (normalized_current_read and normalized_current_read.challenge_year) or user_book.challenge_year,
    format = (normalized_current_read and normalized_current_read.format) or user_book.format,
    tracking_mode = (normalized_current_read and normalized_current_read.tracking_mode) or user_book.tracking_mode,
    shelves = user_book.shelves or {},
    current_reading_instance = normalized_current_read,
    user_book_reads = reads,
  }
end

local function init_array(values)
  return json.util.InitArray(values or {})
end

local function shelf_ids(shelves)
  local ids = {}
  for _, shelf in ipairs(shelves or {}) do
    local id = type(shelf) == "table" and (shelf.id or shelf.shelf_id) or shelf
    if id then table.insert(ids, id) end
  end
  return init_array(ids)
end

local function status_payload(status_id, existing)
  local target_status = PAGEBOUND.SYSTEM_STATUS[status_id]
  if not target_status then return nil end

  local today = pagebound_date()
  local was_finished = existing and existing.status_id == PAGEBOUND.STATUS.FINISHED
  local started_at = existing and existing.started_reading_at
  local finished_at = existing and existing.finished_reading_at
  if not started_at or started_at == "" or (status_id == PAGEBOUND.STATUS.READING and was_finished) then
    started_at = today
  end
  -- Pagebound's own create/update requests include a formatted date here even
  -- for non-finished statuses, so mirror that instead of sending an empty string.
  if status_id == PAGEBOUND.STATUS.FINISHED or not finished_at or finished_at == "" then
    finished_at = today
  end

  return {
    user_book = {
      owned = existing and existing.owned == true or false,
      muted = existing and existing.muted == true or false,
    },
    shelf_ids = shelf_ids(existing and existing.shelves),
    status = target_status,
    date = (existing and existing.date_added) or today,
    started_reading_at = started_at or "",
    finished_reading_at = finished_at or "",
    challenge_year = existing and existing.challenge_year or json.util.null,
    format = (existing and existing.format) or "print",
    tracking_mode = (existing and existing.tracking_mode) or "pages",
    -- Captured Pagebound status create/update calls leave this blank. Progress
    -- requests carry the page count separately.
    total_page_count = "",
    total_minutes = existing and (existing.total_minutes or 0) or json.util.null,
  }
end

function PageboundApi:updateUserBook(book_id, status_id, _page_count, book_uuid)
  if not book_id then return nil end
  book_uuid = linked_book_uuid(self, book_id, book_uuid)
  local payload = status_payload(status_id, nil)
  if not payload then return nil end
  payload.user_book.book_id = tonumber(book_id) or book_id

  local existing, lookup_error = self:findUserBook(book_id, nil, book_uuid)
  if lookup_error then
    if self.settings then
      self.settings:debugWarn("Pagebound: aborting status update because book lookup failed")
    end
    return nil
  end
  local code
  if existing and existing.id then
    payload = status_payload(status_id, existing)
    code = self:request("/api/v1/user_books/" .. urlencode(existing.user_book_uuid or existing.id), "PUT", payload)
  else
    payload.user_book.status = payload.status
    payload.status = nil
    code = self:request("/api/v1/user_books", "POST", payload)
  end

  if not code or code < 200 or code >= 300 then
    if self.settings then self.settings:debugWarn("Pagebound: failed to update book status (HTTP " .. tostring(code) .. ")") end
    return nil
  end
  return self:findUserBook(book_id, nil, book_uuid)
end

function PageboundApi:removeRead(user_book_uuid)
  if not user_book_uuid or user_book_uuid == "" then return nil end
  local code = self:request("/api/v1/user_books/" .. urlencode(user_book_uuid), "DELETE")
  if code and code >= 200 and code < 300 then
    return { id = user_book_uuid }
  end
  return nil
end

function PageboundApi:findBookForum(book_id)
  if not book_id then return nil end
  local path = "/api/v1/forums/find_by_resource?resource_id=" .. urlencode(book_id)
    .. "&resource_type=Book&page=1&post_type=all&sort_by=percent_progress_asc"
  local code, data = self:request(path, "GET")
  if not code then
    return nil, tostring(data or "Pagebound forum lookup request failed")
  end
  if code ~= 200 then
    return nil, "Pagebound forum lookup failed (HTTP " .. tostring(code or "unknown") .. ")"
  end
  if not data or not data.forum or not data.forum.id then
    return nil, "Pagebound forum lookup response did not include a forum ID"
  end
  return data.forum.id
end

function PageboundApi:createForumPost(book_id, title, content)
  local forum_id, forum_error = self:findBookForum(book_id)
  if not forum_id then
    return nil, forum_error or "Could not find the Pagebound forum for this book"
  end

  local code, data = self:request("/api/v1/posts", "POST", {
    post = {
      forum_id = forum_id,
      title = title,
      content = content,
      is_spoiler = false,
    },
    total_page_count = json.util.null,
  })
  if not code then
    return nil, tostring(data or "Pagebound forum post request failed")
  end
  if code ~= 201 and code ~= 200 then
    return nil, "Pagebound forum post failed (HTTP " .. tostring(code or "unknown") .. ")"
  end
  -- Some successful API responses may omit a JSON body; the HTTP status still
  -- confirms that the post was accepted.
  return data or true
end

local function pagebound_note_title(data, status, settings)
  local percent = tonumber(data.progress_percent)
  local page = tonumber(data.local_page)
  local total_pages = tonumber(data.local_total_pages)

  if not percent then
    local remote_total = tonumber(status.total_page_count or status.page_count)
      or tonumber(settings and settings:pages())
    local progress = tonumber(data.progress) or 0
    if data.progress_type == "pages" and remote_total and remote_total > 0 then
      percent = math.floor(progress * 100 / remote_total + 0.5)
    else
      percent = math.floor(progress + 0.5)
    end
  end

  percent = math.max(0, math.min(100, math.floor(percent + 0.5)))

  if not page or not total_pages or total_pages <= 0 then
    local remote_total = tonumber(status.total_page_count or status.page_count)
      or tonumber(settings and settings:pages())
    local progress = tonumber(data.progress) or 0
    if data.progress_type == "pages" then
      page = page or math.floor(progress + 0.5)
      total_pages = total_pages or remote_total
    elseif remote_total and remote_total > 0 then
      page = page or math.floor(percent * remote_total / 100 + 0.5)
      total_pages = total_pages or remote_total
    end
  end

  local page_text = page and total_pages and total_pages > 0
    and (math.floor(page + 0.5) .. "/" .. math.floor(total_pages + 0.5)) or "?/?"
  return ("Thoughts from %d%% (page %s)"):format(percent, page_text)
end

function PageboundApi:updateProgress(book_id, status, current_read, value, update_type)
  if not book_id then return nil, "No linked book found on Pagebound" end

  status = status or self:findUserBook(book_id)
  if not status or not status.id then
    status = self:updateUserBook(book_id, PAGEBOUND.STATUS.READING)
  end
  if not status then return nil, "Could not start a Pagebound reading session" end

  current_read = current_read or status.current_reading_instance
  if not current_read or not current_read.id then
    status = self:updateUserBook(book_id, PAGEBOUND.STATUS.READING, status.total_page_count or status.page_count)
    current_read = status and status.current_reading_instance
  end
  if not current_read or not current_read.id then
    return nil, "No active reading session found on Pagebound"
  end

  local user_book_id = tonumber(current_read.user_book_id) or tonumber(status.user_book_id)
  if not user_book_id then return nil, "Pagebound user book id is missing" end

  local reading_update = {
    user_book_id = user_book_id,
    date = pagebound_date(),
    reading_instance_id = current_read.id,
  }
  local user_book = {}
  local progress_method
  if update_type == "pages" then
    local page = math.floor((tonumber(value) or 0) + 0.5)
    local previous_page = tonumber(status.current_page) or 0
    local page_delta = math.max(0, page - previous_page)
    local total_pages = tonumber(status.total_page_count or status.page_count)
      or tonumber(self.settings and self.settings:readBookSetting(self.settings:getFilePath(), "pages"))
    reading_update.total_progress = page_delta
    reading_update.total_pages_read = tostring(page)
    user_book.current_page = tostring(page)
    user_book.total_page_count = total_pages and tostring(total_pages) or ""
    user_book.current_minute = json.util.null
    user_book.total_minutes = json.util.null
    progress_method = "pages"
  else
    local percent = math.floor(math.max(0, math.min(100, tonumber(value) or 0)) + 0.5)
    reading_update.total_progress = percent
    reading_update.total_pages_read = json.util.null
    user_book.current_page = json.util.null
    user_book.total_page_count = json.util.null
    user_book.current_minute = json.util.null
    user_book.total_minutes = json.util.null
    progress_method = "percent"
  end

  local payload = {
    reading_update = reading_update,
    user_book = user_book,
    no_broadcast = false,
    progress_method = progress_method,
  }
  local code, data = self:request("/api/v1/reading_updates", "POST", payload)
  if code ~= 201 and code ~= 200 then
    return nil, "Pagebound progress update failed (HTTP " .. tostring(code or "unknown") .. ")"
  end
  return self:findUserBook(book_id)
end

-- Pagebound's captured note flow creates a post in the forum attached to the
-- book resource. Progress is saved first; if posting fails, return the saved
-- status plus an error so the dialog can report the partial success.
function PageboundApi:createJournalEntry(data)
  if not data or not data.book_id then
    logger.warn("Pagebound: journal entry stopped because no linked book ID was provided")
    return nil, "No linked Pagebound book found"
  end

  logger.info("Pagebound: saving progress for journal entry")
  local status = self:findUserBook(data.book_id)
  if not status or not status.status_id then
    status = self:updateUserBook(data.book_id, PAGEBOUND.STATUS.READING)
  end
  if not status then
    logger.warn("Pagebound: journal entry stopped because a reading session could not be started")
    return nil, "Could not start a Pagebound reading session"
  end
  local current_read = status.current_reading_instance
    or (status.user_book_reads and status.user_book_reads[#status.user_book_reads])
  local updated, progress_error = self:updateProgress(
    data.book_id, status, current_read, data.progress, data.progress_type
  )
  if not updated then
    progress_error = progress_error or "Pagebound progress update failed"
    logger.warn("Pagebound: journal entry stopped before forum posting: " .. tostring(progress_error))
    return nil, progress_error
  end

  local note = tostring(data.text or "")
  if note:match("%S") then
    local title = pagebound_note_title(data, status, self.settings)
    logger.info("Pagebound: posting journal note to the book forum")
    local post, post_error = self:createForumPost(data.book_id, title, note)
    if not post then
      post_error = post_error or "unknown error"
      logger.warn("Pagebound: forum note posting failed: " .. tostring(post_error))
      return updated, "Progress was saved to Pagebound, but the note could not be posted: " .. tostring(post_error)
    end
    logger.info("Pagebound: forum note posted successfully")
  else
    logger.info("Pagebound: note text was blank; progress saved without a forum post")
  end
  return updated
end

return PageboundApi
