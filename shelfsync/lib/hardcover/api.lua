local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local config = (config_ok and shelfsync_config.hardcover) or {}
local logger = require("shelfsync/lib/common/safe_logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local os = require("os")
local _t = require("shelfsync/lib/common/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local Book = require("shelfsync/lib/common/book")
local VERSION = require("shelfsync_version")

local SETTING = require("shelfsync/lib/common/constants/settings")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local OAuthClient = require("shelfsync/lib/hardcover/oauth_client")
local OAUTH = require("shelfsync/lib/hardcover/oauth_constants")

local api_url = "https://api.hardcover.app/v1/graphql"

local function formatErrors(errors)
  if type(errors) ~= "table" then
    return tostring(errors or "unspecified GraphQL error")
  end

  local messages = {}
  for _, item in ipairs(errors) do
    local message
    if type(item) == "table" then
      message = item.message or item.error or "GraphQL error"
      local code = item.extensions and item.extensions.code
      if code then
        message = tostring(message) .. " (code: " .. tostring(code) .. ")"
      end
    else
      message = tostring(item)
    end
    -- Keep diagnostics readable and avoid multi-line or unbounded log entries.
    message = tostring(message):gsub("[%c]", " ")
    if #message > 500 then
      message = message:sub(1, 500) .. "..."
    end
    table.insert(messages, message)
  end

  if #messages == 0 then
    return "unspecified GraphQL error"
  end
  return table.concat(messages, "; ")
end

local function safeGraphQLErrorCodes(errors)
  local codes = {}
  for _, item in ipairs(type(errors) == "table" and errors or {}) do
    local code = type(item) == "table" and item.extensions and item.extensions.code
    if type(code) == "string" and #code <= 64 and code:match("^[%w_%-]+$") then
      codes[#codes + 1] = code
    end
  end
  return #codes > 0 and table.concat(codes, ",") or "none"
end

local function formatRequestError(err)
  if type(err) == "string" then
    return err
  end
  if type(err) ~= "table" then
    return "no response or error details returned"
  end

  if err.errors then
    return formatErrors(err.errors)
  elseif err.parse_error then
    return "could not decode API response: " .. tostring(err.parse_error)
  elseif err.request_error then
    return "request failed: " .. tostring(err.request_error)
  elseif err.completed == false then
    return "request subprocess did not complete"
  end
  return "no response or error details returned"
end

local function sortedPayloadFields(object)
  local fields = {}
  for key in pairs(type(object) == "table" and object or {}) do
    table.insert(fields, tostring(key))
  end
  table.sort(fields)
  return table.concat(fields, ",")
end

-- The journal dialog's shared data is intentionally provider-neutral. Hardcover
-- stores notes, progress and dates in a different shape from StoryGraph's
-- progress-with-note endpoint. A journal entry is always a new record, so
-- without the account's default privacy it falls back to Private rather than
-- Public.
local function mapJournalData(data, default_privacy_setting_id)
  local object = {
    book_id = tonumber(data.book_id),
    event = data.event_type == "quote" and "quote" or "note",
    entry = data.text or "",
    edition_id = tonumber(data.edition_id),
    privacy_setting_id = tonumber(data.privacy_setting_id)
      or tonumber(default_privacy_setting_id)
      or HARDCOVER.PRIVACY.PRIVATE,
    -- The API requires tags even when the reader has not supplied any.
    tags = json.util.InitArray({}),
  }

  local date = data.date
  if type(date) == "table" and date.year and date.month and date.day then
    object.action_at = string.format("%04d-%02d-%02d", date.year, date.month, date.day)
  end

  -- Hardcover stores a page position in metadata.position. Convert percentage
  -- progress to the selected Hardcover edition's page count when available.
  local value, possible
  local remote_total_pages = tonumber(data.remote_total_pages)
  if data.progress_type == "pages" then
    value = tonumber(data.progress)
    possible = remote_total_pages
    if not possible or possible <= 0 then
      value = tonumber(data.local_page)
      possible = tonumber(data.local_total_pages)
    end
  else
    local percent = tonumber(data.progress_percent or data.progress)
    if percent and remote_total_pages and remote_total_pages > 0 then
      value = math.floor((percent / 100) * remote_total_pages + 0.5)
      possible = remote_total_pages
    else
      value = tonumber(data.local_page)
      possible = tonumber(data.local_total_pages)
    end
  end

  if value and possible and possible > 0 then
    object.metadata = {
      position = {
        type = "pages",
        value = math.max(0, math.min(math.floor(value + 0.5), math.floor(possible + 0.5))),
        possible = math.floor(possible + 0.5),
      },
    }
  end

  return object
end

local HardcoverApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
}

local function get_api_token(self)
  local token = ""
  if self.settings then
    token = self.settings:readSetting(SETTING.HARDCOVER.API_TOKEN)
  end
  if not token or token == "" then token = config.token or "" end
  return token
end

function HardcoverApi:getAuthMethod()
  if self.settings and self.settings:hasOAuthSession() then
    return "oauth"
  end
  if get_api_token(self) ~= "" then
    return "api_token"
  end
end

-- OAuth wins whenever a session is active. The configured token (including
-- the legacy config.lua value) remains the fallback when OAuth is signed out.
local function get_headers(self)
  local token
  if self.settings and self.settings:hasOAuthSession() then
    token = self.settings:readSetting(SETTING.HARDCOVER.ACCESS_TOKEN)
  end
  if not token or token == "" then
    token = get_api_token(self)
  end

  if token == "" then
    logger.warn("Hardcover: No OAuth session or API token found")
  end

  return {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = T("shelfsync.koplugin/%1 (https://github.com/Lyfts/ShelfSync)",
      table.concat(VERSION, ".")),
    Authorization = "Bearer " .. token,
  }
end

function HardcoverApi:hasCredential()
  return self:getAuthMethod() ~= nil
end

function HardcoverApi:saveOAuthTokens(tokens)
  if not self.settings or not tokens or not tokens.access_token then
    return false
  end
  self.settings:saveOAuthTokens(tokens, true)
  return true
end

-- Persist which OAuth scope set the saved grant covers. Increment
-- OAUTH.SCOPE_REVISION when the requested scopes change; existing sessions
-- are logged out once so the next sign-in grants the new permissions.
function HardcoverApi:checkOAuthScopeRevision()
  if not self.settings then
    return false
  end

  local saved_revision = tonumber(self.settings:readSetting(SETTING.HARDCOVER.OAUTH_SCOPE_REVISION))
  if saved_revision == OAUTH.SCOPE_REVISION then
    return false
  end

  local had_oauth_session = self.settings:hasOAuthSession()
  if had_oauth_session then
    self:logoutOAuth()
    self.settings:updateSetting(SETTING.HARDCOVER.OAUTH_SCOPE_NOTICE_PENDING, true)
  end
  self.settings:updateSetting(SETTING.HARDCOVER.OAUTH_SCOPE_REVISION, OAUTH.SCOPE_REVISION)
  return had_oauth_session
end

function HardcoverApi:refreshOAuthToken()
  if not self.settings then
    return false, "No settings available"
  end

  local refresh_token = self.settings:readSetting(SETTING.HARDCOVER.REFRESH_TOKEN)
  if not refresh_token or refresh_token == "" then
    self.settings:clearOAuthSession()
    return false, "rejected"
  end

  local tokens, err = OAuthClient:refresh(refresh_token)
  if tokens then
    self.settings:saveOAuthTokens(tokens, false)
    return true
  end
  if err == "rejected" then
    self.settings:clearOAuthSession()
  end
  return false, err
end

function HardcoverApi:logoutOAuth()
  if not self.settings then
    return
  end

  local access_token = self.settings:readSetting(SETTING.HARDCOVER.ACCESS_TOKEN)
  local refresh_token = self.settings:readSetting(SETTING.HARDCOVER.REFRESH_TOKEN)
  -- Clear local credentials even if Hardcover's revocation endpoint is
  -- temporarily unavailable. Revoke both token types on a best-effort basis.
  self.settings:clearOAuthSession()
  Trapper:wrap(function()
    OAuthClient:revoke(refresh_token, "refresh_token")
    OAuthClient:revoke(access_token, "access_token")
  end)
end

local book_fragment = [[
fragment BookParts on books {
  book_id: id
  title
  release_year
  users_read_count
  pages
  book_series {
    position
    series {
      name
    }
  }
  contributions: cached_contributors
  author_contributions: contributions {
    contribution
    author {
      name
    }
  }
  cached_image
  user_books(where: { user_id: { _eq: $userId }}) {
    id
  }
}]]

local edition_fragment = book_fragment .. [[
fragment EditionParts on editions {
  id
  book {
    ...BookParts
  }
  cached_image
  edition_format
  language {
    code2
    language
  }
  pages
  publisher {
    name
  }
  release_date
  reading_format_id
  title
  users_count
}]]

local user_book_fragment = [[
fragment UserBookParts on user_books {
  id
  book_id
  status_id
  edition_id
  privacy_setting_id
  rating
  user_book_reads(order_by: {id: asc}) {
    id
    started_at
    finished_at
    progress_pages
    edition_id
  }
}]]

function HardcoverApi:me()
  local result = self:query([[{
    me {
      id
      account_privacy_setting_id
    }
  }]])

  if result and result.me then
    return result.me[1] or {}
  end
  return {}
end

local function graphQLErrorsAreAuthErrors(errors)
  for _, item in ipairs(type(errors) == "table" and errors or {}) do
    local message = type(item) == "table" and (item.message or item.error) or item
    if message then
      local normalized = tostring(message):lower()
      if normalized:find(HARDCOVER.ERROR.JWT:lower(), 1, true)
          or normalized:find(HARDCOVER.ERROR.TOKEN:lower(), 1, true)
          or normalized:find("invalid_token", 1, true)
          or normalized:find("invalid_grant", 1, true) then
        return true
      end
    end
  end
  return false
end

local function isAuthFailure(status_code, data)
  if tonumber(status_code) == 401 then
    return true
  end
  if type(data) ~= "table" then
    return false
  end
  local oauth_error = tostring(data.error or ""):lower()
  if oauth_error == "invalid_token" or oauth_error == "invalid_grant" then
    return true
  end
  return graphQLErrorsAreAuthErrors(data.errors)
end

local function queryOnce(self, query, parameters, preserve_graphql_errors)
  -- Subprocess forking occasionally fails to complete on some devices (no
  -- network-level error, the fork itself just doesn't come back); one retry
  -- recovers most of these transient failures instead of failing outright.
  local completed, content
  for attempt = 1, 2 do
    completed, content = Trapper:dismissableRunInSubprocess(function()
      return self:_query(query, parameters)
    end, true, true)
    if completed then break end
  end

  if not (completed and content) then
    return nil, { completed = completed }
  end

  local code, response = string.match(content, "^([^:]*):(.*)")
  local status_code = tonumber(code)
  if not status_code then
    return nil, {
      completed = false,
      request_error = code or "response did not include an HTTP status",
    }
  end
  if status_code == 401 then
    return nil, {
      status_code = status_code,
      auth_error = true,
      request_error = "Hardcover rejected the current credential",
    }
  end

  local decoded, data, decode_error = pcall(json.decode, response, json.decode.simple)
  if not decoded or type(data) ~= "table" then
    return nil, {
      status_code = status_code,
      parse_error = decoded and tostring(decode_error or "response was not a JSON object") or tostring(data),
    }
  end

  local auth_error = isAuthFailure(status_code, data)
  if data.data then
    if preserve_graphql_errors and data.errors then
      return data.data, {
        errors = data.errors,
        status_code = status_code,
        auth_error = auth_error,
      }
    end
    return data.data
  elseif data.errors or data.error then
    return nil, {
      errors = data.errors or { data.error },
      status_code = status_code,
      auth_error = auth_error,
    }
  elseif auth_error then
    return nil, {
      status_code = status_code,
      auth_error = true,
      request_error = data.error_description or "Hardcover rejected the current credential",
    }
  elseif status_code < 200 or status_code >= 300 then
    return nil, {
      status_code = status_code,
      request_error = "Hardcover returned HTTP " .. tostring(status_code),
    }
  end

  return nil, {
    status_code = status_code,
    request_error = "GraphQL response contained neither data nor errors",
  }
end

function HardcoverApi:query(query, parameters, preserve_graphql_errors)
  if not self.enabled or not NetworkManager:isConnected() then
    return
  end

  local auth_method = self:getAuthMethod()
  if not auth_method then
    return nil, { request_error = "No Hardcover OAuth login or API token is configured" }
  end

  local refresh_attempted = false
  if auth_method == "oauth" and self.settings:isOAuthTokenExpired() then
    refresh_attempted = true
    local refreshed, refresh_error = self:refreshOAuthToken()
    if not refreshed then
      if refresh_error == "rejected" then
        auth_method = self:getAuthMethod()
        if not auth_method then
          local auth_error = { auth_error = true, request_error = "Hardcover OAuth login expired" }
          self:notifyIfAuthError(auth_error)
          return nil, auth_error
        end
      else
        return nil, { request_error = "Could not refresh Hardcover OAuth login: " .. tostring(refresh_error) }
      end
    end
  end

  local result, err = queryOnce(self, query, parameters, preserve_graphql_errors)

  -- If an OAuth access token is rejected, refresh it once. A definitive
  -- rejection clears that session and retries with the configured API token
  -- when present. Network failures during refresh preserve OAuth precedence.
  if auth_method == "oauth" and err and err.auth_error then
    if not refresh_attempted then
      refresh_attempted = true
      local refreshed, refresh_error = self:refreshOAuthToken()
      if refreshed then
        result, err = queryOnce(self, query, parameters, preserve_graphql_errors)
      elseif refresh_error ~= "rejected" then
        return nil, { request_error = "Could not refresh Hardcover OAuth login: " .. tostring(refresh_error) }
      end
    end

    if err and err.auth_error then
      if self.settings:hasOAuthSession() then
        self.settings:clearOAuthSession()
      end
      if get_api_token(self) ~= "" then
        result, err = queryOnce(self, query, parameters, preserve_graphql_errors)
      end
    end
  end

  if err and err.auth_error then
    self:notifyIfAuthError(err)
  end
  return result, err
end

-- Notify once per cooldown when neither OAuth nor the API token can
-- authenticate a request. The engine pauses syncing and shows account help.
function HardcoverApi:notifyIfAuthError(error_info)
  local is_auth_error = type(error_info) == "table"
    and (error_info.auth_error == true or tonumber(error_info.status_code) == 401)
  local errors = type(error_info) == "table" and (error_info.errors or error_info) or { error_info }
  if not is_auth_error then
    is_auth_error = graphQLErrorsAreAuthErrors(errors)
  end
  if not is_auth_error then
    return
  end

  local now = os.time()
  if self.last_auth_warning and now - self.last_auth_warning < 300 then
    return
  end
  self.last_auth_warning = now
  if self.on_error then
    self.on_error("Unauthorized")
  end
end

function HardcoverApi:_query(query, parameters)
  local requestBody = {
    query = query,
    variables = parameters
  }

  local maxtime = 12
  local timeout = 6

  local sink = {}
  socketutil:set_timeout(timeout, maxtime or 30)
  local request = {
    url = api_url,
    method = "POST",
    headers = get_headers(self),
    source = ltn12.source.string(json.encode(requestBody)),
    sink = socketutil.table_sink(sink),
  }

  local _, code, response_headers = http.request(request)
  socketutil:reset_timeout()

  local content = table.concat(sink) -- empty or content accumulated till now
  if code == socketutil.TIMEOUT_CODE or
    code == socketutil.SSL_HANDSHAKE_CODE or
    code == socketutil.SINK_TIMEOUT_CODE
  then
    logger.warn("Hardcover: request interrupted:", code)
    return code .. ':'
  end

  if type(code) == "string" then
    logger.dbg("Hardcover: Request failed; transport error length=" .. #code)
  end

  if type(code) == "number" and (code < 200 or code > 299) then
    logger.dbg("Hardcover: Request error", code,
      "content_type=" .. tostring(response_headers and response_headers["content-type"] or "unknown"),
      "response_length=" .. #content)
  end

  return tostring(code or "unknown") .. ':' .. content
end

function HardcoverApi:hydrateBooks(ids, user_id)
  if #ids == 0 then
    return {}
  end

  local bookQuery = [[
    query ($ids: [Int!], $userId: Int!) {
      books(where: { id: { _in: $ids }}) {
        ...BookParts
      }
    }
  ]] .. book_fragment

  local books = self:query(bookQuery, { ids = ids, userId = user_id })
  if books then
    local list = books.books

    if #list > 1 then
      local id_order = {}

      for i, v in ipairs(ids) do
        id_order[v] = i
      end

      -- sort books by original ID order
      table.sort(list, function(a, b)
        return id_order[a.book_id] < id_order[b.book_id]
      end)
    end

    return list
  end
end

function HardcoverApi:hydrateBookFromEdition(edition_id, user_id)
  local editionSearch = [[
    query ($id: Int!, $userId: Int!) {
      editions(where: { id: { _eq: $id }}) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(editionSearch, { id = edition_id, userId = user_id })
  if editions and editions.editions and #editions.editions > 0 then
    return self:normalizedEdition(editions.editions[1])
  end
end

function HardcoverApi:findBookBySlug(slug, user_id)
  local slugSearch = [[
    query ($slug: String!, $userId: Int!) {
      books(where: { slug: { _eq: $slug }}) {
        ...BookParts
      }
    }]] .. book_fragment

  local books = self:query(slugSearch, { slug = slug, userId = user_id })
  if books and books.books and #books.books > 0 then
    return books.books[1]
  end
end

function HardcoverApi:findEditions(book_id, user_id)
  local edition_search = [[
    query ($id: Int!, $userId: Int!) {
      editions(where: { book_id: { _eq: $id }, _or: [{reading_format_id: { _is_null: true }}, {reading_format_id: { _neq: 2 }} ]},
      order_by: { users_count: desc_nulls_last }) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(edition_search, { id = book_id, userId = user_id })
  if not editions or not editions.editions then
    return {}
  end
  local edition_list = editions.editions

  if #edition_list > 1 then
    -- prefer editions with user reads
    local edition_ids = _t.map(edition_list, function(edition)
      return edition.id
    end)

    local read_search = [[
      query ($ids: [Int!], $userId: Int!) {
        user_books(where: { edition_id: { _in: $ids }, user_id: { _eq: $userId }}) {
          edition_id
        }
      }
    ]]

    local read_editions = self:query(read_search, { ids = edition_ids, userId = user_id })
    if not read_editions then
      return nil
    end
    local read_index = {}
    for _, read in ipairs(read_editions) do
      read_index[read.edition_id] = true
    end

    table.sort(edition_list, function(a, b)
      -- sort by user reads
      local read_a = read_index[a.id]
      local read_b = read_index[b.id]

      if read_a ~= read_b then
        return read_a == true
      end

      if a.reading_format_id ~= b.reading_format_id then
        return a.reading_format_id == 4
      end

      if a.users_count ~= b.users_count then
        return a.users_count > b.users_count
      end

      return false
    end)
  end

  return _t.map(edition_list, function(edition)
    return self:normalizedEdition(edition)
  end)
end

function HardcoverApi:search(title, author, userId, page)
  page = page or 1
  local query = [[
    query ($query: String!, $page: Int!) {
      search(query: $query, per_page: 25, page: $page, query_type: "Book") {
        ids
      }
    }]]
  local search = title .. " " .. (author or "")
  local results, error = self:query(query, { query = search, page = page })
  if error then
    return nil, error
  end

  if not results or not _t.dig(results, "search", "ids") then
    return {}
  end

  local ids = _t.map(results.search.ids, function(id) return tonumber(id) end)
  return self:hydrateBooks(ids, userId)
end

function HardcoverApi:findBookByIdentifiers(identifiers, user_id)
  local isbnKey

  if identifiers.edition_id then
    local book = self:hydrateBookFromEdition(identifiers.edition_id, user_id)
    if book then
      return book
    end
  end

  if identifiers.book_slug then
    -- book_slug may actually be a numeric edition id (see Book:parseIdentifiers,
    -- which collapses hardcover-edition:<id> tags into book_slug), so fall back
    -- to treating it as one before giving up on a purely-numeric value.
    local book = self:findBookBySlug(identifiers.book_slug, user_id)
    if book then
      return book
    end

    if tonumber(identifiers.book_slug) then
      book = self:hydrateBookFromEdition(tonumber(identifiers.book_slug), user_id)
      if book then
        return book
      end
    end
  end

  if identifiers.isbn_13 then
    isbnKey = 'isbn_13'
  elseif identifiers.isbn_10 then
    isbnKey = 'isbn_10'
  end

  if isbnKey then
    local editionSearch = [[
      query ($isbn: String!, $userId: Int!) {
        editions(where: { ]] .. isbnKey .. [[: { _eq: $isbn }}) {
          ...EditionParts
        }
      }]] .. edition_fragment

    local editions = self:query(editionSearch, { isbn = tostring(identifiers[isbnKey]), userId = user_id })
    if editions and editions.editions and #editions.editions > 0 then
      return self:normalizedEdition(editions.editions[1])
    end
  end
end

function HardcoverApi:normalizedEdition(edition)
  local result = edition.book

  result.edition_id = edition.id
  result.edition_format = Book:editionFormatName(edition.edition_format, edition.reading_format_id)

  result.cached_image = edition.cached_image
  result.publisher = edition.publisher and edition.publisher.name
  if edition.release_date then
    local year = edition.release_date:match("^(%d%d%d%d)-")
    result.release_year = year
  else
    result.release_year = nil
  end
  result.language = edition.language
  result.title = edition.title
  result.reads = edition.reads
  result.pages = edition.pages
  result.filetype = result.edition_format or "Physical Book"
  result.users_count = edition.users_count

  return result
end

function HardcoverApi:normalizeUserBookRead(user_book_read)
  local user_book = user_book_read.user_book
  user_book_read.user_book = nil
  user_book.user_book_reads = { user_book_read }
  return user_book
end

function HardcoverApi:findBooks(title, author, userId)
  if not title or string.match(title, "^%s*$") then
    return {}
  end

  title = title:gsub(":.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return self:search(title, author, userId)
end

function HardcoverApi:getRandomToRead(user_id, limit)
  limit = limit or 10

  local read_query = [[
    query ($userId: Int!) {
      user_books(where: { status_id: { _eq:1 }, user_id: { _eq: $userId }}) {
        book_id
      }
    }
  ]]
  local results, err = self:query(read_query, { userId = user_id })
  if not results or not results.user_books then
    return {}, err
  end

  local ids = _t.map(results.user_books, function(result) return tonumber(result.book_id) end)
  _t.shuffle(ids)

  return self:hydrateBooks(_t.slice(ids, 1, limit), user_id)
end

function HardcoverApi:findUserBook(book_id, user_id)
  -- this may not be adequate, as (it's possible) there could be more than one read in progress? Maybe?
  local read_query = [[
    query ($id: Int!, $userId: Int!) {
      user_books(where: { book_id: { _eq: $id }, user_id: { _eq: $userId }}) {
        ...UserBookParts
      }
    }
  ]] .. user_book_fragment

  local results, err = self:query(read_query, { id = book_id, userId = user_id })
  if not results or not results.user_books then
    return {}, err
  end

  return results.user_books[1]
end

function HardcoverApi:createRead(user_book_id, edition_id, page, started_at)
  local query = [[
    mutation InsertUserBookRead($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      insert_user_book_read(user_book_id: $id, user_book_read: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result = self:query(query, { id = user_book_id, pages = page, editionId = edition_id, startedAt = started_at })
  if result and result.insert_user_book_read then
    local user_book_read = result.insert_user_book_read.user_book_read
    return self:normalizeUserBookRead(user_book_read)
  end
end

function HardcoverApi:updatePage(user_read_id, edition_id, page, started_at)
  local query = [[
    mutation UpdateBookProgress($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result = self:query(query, { id = user_read_id, pages = page, editionId = edition_id, startedAt = started_at })
  if result and result.update_user_book_read then
    return self:normalizeUserBookRead(result.update_user_book_read.user_book_read)
  end
end

function HardcoverApi:updateUserBook(book_id, status_id, privacy_setting_id, edition_id)
  if not privacy_setting_id then
    -- insert_user_book also updates existing records. Preserve their privacy;
    -- use the account default (or Private) only after confirming the book is new.
    local me = self:me()
    if not me.id then
      return nil, { request_error = "Could not determine Hardcover user" }
    end

    local existing, lookup_error = self:findUserBook(book_id, me.id)
    if lookup_error then
      return nil, lookup_error
    end

    privacy_setting_id = tonumber(existing and existing.privacy_setting_id)
    if existing and not privacy_setting_id then
      return nil, { request_error = "Could not determine existing book privacy" }
    end
    privacy_setting_id = privacy_setting_id or tonumber(me.account_privacy_setting_id)
      or HARDCOVER.PRIVACY.PRIVATE
  end

  local query = [[
    mutation ($object: UserBookCreateInput!) {
      insert_user_book(object: $object) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local update_args = {
    book_id = book_id,
    privacy_setting_id = privacy_setting_id,
    status_id = status_id,
    edition_id = edition_id
  }

  local result, request_error = self:query(query, { object = update_args })
  if result and result.insert_user_book then
    return result.insert_user_book.user_book, result.insert_user_book.error
  end
  return nil, request_error
end

function HardcoverApi:updateRating(user_book_id, rating)
  local query = [[
    mutation ($id: Int!, $rating: numeric) {
      update_user_book(id: $id, object: { rating: $rating }) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  if rating == 0 or rating == nil then
    rating = json.util.null
  end

  local result = self:query(query, { id = user_book_id, rating = rating })
  if result and result.update_user_book then
    return result.update_user_book.user_book
  end
end

-- Hardcover stores reviews as a Slate.js rich-text document (`review_slate`,
-- jsonb); `review_raw`/`review` are read-only plain-text/HTML mirrors
-- derived from it server-side, not writable input fields (confirmed against
-- github.com/Billiam/hardcoverapp.koplugin PR #55). Splits on blank lines
-- into one paragraph block per line, matching that reference implementation.
local function paragraph_block(text)
  return {
    data = {},
    type = "paragraph",
    object = "block",
    children = { { text = text, object = "text" } },
  }
end

local function build_slate_document(plain_text)
  if not plain_text or plain_text:match("^%s*$") then
    return nil
  end

  local children = {}
  local last_end = 1
  while true do
    local start_idx, end_idx = plain_text:find("\n\n", last_end, true)
    if not start_idx then
      local segment = plain_text:sub(last_end)
      if not segment:match("^%s*$") then
        table.insert(children, paragraph_block(segment))
      end
      break
    end
    local segment = plain_text:sub(last_end, start_idx - 1)
    if not segment:match("^%s*$") then
      table.insert(children, paragraph_block(segment))
    end
    last_end = end_idx + 1
  end

  return { document = { object = "document", children = children } }
end

-- Rating + review text in one mutation, for the unified Review menu.
function HardcoverApi:updateReview(user_book_id, rating, review_text)
  local declarations, fields = {}, {}
  local variables = { id = user_book_id }
  if rating ~= nil then
    declarations[#declarations + 1] = "$rating: numeric"
    fields[#fields + 1] = "rating: $rating"
    variables.rating = rating == 0 and json.util.null or rating
  end
  if review_text ~= nil then
    declarations[#declarations + 1] = "$review: jsonb"
    fields[#fields + 1] = "review_slate: $review"
    variables.review = build_slate_document(review_text) or json.util.null
  end
  if #fields == 0 then return nil, "No rating or review text supplied" end
  local query = [[
    mutation ($id: Int!, %s) {
      update_user_book(id: $id, object: { %s }) {
        error
        user_book { ...UserBookParts }
      }
    }
  ]]
  query = query:format(table.concat(declarations, ", "), table.concat(fields, ", ")) .. user_book_fragment

  local result, err = self:query(query, variables)
  local updated = result and result.update_user_book
  if updated and updated ~= json.util.null then
    if updated.error and updated.error ~= json.util.null and updated.error ~= "" then
      err = updated.error
    elseif updated.user_book and updated.user_book ~= json.util.null and updated.user_book.id then
      return updated.user_book
    end
  end
  local reason = type(err) == "string" and err or (err and json.encode(err))
    or "Hardcover returned no saved review"
  logger.warn("Hardcover: updateReview failed - " .. reason)
  return nil, reason
end

function HardcoverApi:removeRead(user_book_id)
  local query = [[
    mutation($id: Int!) {
      delete_user_book(id: $id) {
        id
      }
    }
  ]]
  local result = self:query(query, { id = user_book_id })
  if result then
    return result.delete_user_book
  end
end

function HardcoverApi:createJournalEntry(dialog_data)
  dialog_data = dialog_data or {}
  local default_privacy_setting_id = self:me().account_privacy_setting_id
  local object = mapJournalData(dialog_data, default_privacy_setting_id)

  local query = [[
    mutation InsertReadingJournalEntry($object: ReadingJournalCreateType!) {
      insert_reading_journal(object: $object) {
        errors
        id
      }
    }
  ]]

  local result, request_error = self:query(query, { object = object }, true)
  local inserted = result and result.insert_reading_journal
  -- The mutation's ID confirms the write. Avoid selecting the nested
  -- reading_journal row here, as that also requires permission to read journal
  -- entries and is unnecessary for the caller to report success.
  if inserted and inserted.id then
    return inserted
  end

  local details
  if inserted and inserted.errors and #inserted.errors > 0 then
    details = formatErrors(inserted.errors)
  elseif request_error then
    details = formatRequestError(request_error)
  elseif result and not inserted then
    details = "API response did not include insert_reading_journal"
  elseif inserted then
    details = "mutation returned no journal entry ID or error details"
  elseif not self.enabled then
    details = "request skipped because Hardcover sync is disabled"
  elseif not NetworkManager:isConnected() then
    details = "request skipped because the network is disconnected"
  else
    details = "no response or error details returned"
  end

  if type(request_error) == "table" and request_error.status_code then
    details = "HTTP " .. tostring(request_error.status_code) .. ": " .. details
  end

  local graph_errors = (inserted and inserted.errors)
    or (type(request_error) == "table" and request_error.errors)
  logger.warn("Hardcover: Reading-journal mutation failed (status_code="
    .. tostring(type(request_error) == "table" and request_error.status_code or "unknown")
    .. ", error_count=" .. tostring(type(graph_errors) == "table" and #graph_errors or 0)
    .. ", error_codes=" .. safeGraphQLErrorCodes(graph_errors)
    .. ", details_length=" .. #details
    .. ", payload fields=" .. sortedPayloadFields(object)
    .. ", book_id_type=" .. type(type(object) == "table" and object.book_id)
    .. ", entry_present=" .. tostring(type(object) == "table" and object.entry ~= nil) .. ")")

  return nil, "Hardcover note sync failed; see the KOReader log for status and error codes."
end

return HardcoverApi
