local _ = require("gettext")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local url = require("socket.url")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local VERSION = require("shelfsync_version")

local OAUTH = require("shelfsync/lib/hardcover/oauth_constants")

local OAuthClient = {}
local user_agent = ("ShelfSync/%s (https://github.com/Lyfts/ShelfSync)")
  :format(table.concat(VERSION, "."))

local function formEncode(fields)
  local parts = {}
  for key, value in pairs(fields) do
    if value ~= nil then
      table.insert(parts, url.escape(tostring(key)) .. "=" .. url.escape(tostring(value)))
    end
  end
  return table.concat(parts, "&")
end

-- Return "status:body" so the caller can parse the response in the parent
-- process. KOReader's subprocess settings are snapshots and should not be
-- mutated from this request worker.
local function postForm(path, fields)
  local body = formEncode(fields)
  local sink = {}
  socketutil:set_timeout(10, 20)

  local ok, result, code = pcall(http.request, {
    url = OAUTH.API_BASE .. path,
    method = "POST",
    headers = {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Content-Length"] = tostring(#body),
      ["User-Agent"] = user_agent,
    },
    source = ltn12.source.string(body),
    sink = socketutil.table_sink(sink),
  })
  socketutil:reset_timeout()

  if not ok then
    return "network_error:" .. tostring(result)
  end
  return tostring(code or result or "network_error") .. ":" .. table.concat(sink)
end

local function parseResponse(raw)
  if type(raw) ~= "string" then
    return nil, nil, "No response from Hardcover OAuth"
  end

  local status, body = raw:match("^([^:]*):(.*)$")
  local status_code = tonumber(status)
  if not status_code then
    return nil, nil, body ~= "" and body or "OAuth request failed"
  end
  -- OAuth revocation endpoints may return HTTP 200 with no response body.
  if body == "" then
    return {}, status_code
  end

  local ok, data = pcall(json.decode, body, json.decode.simple)
  if not ok or type(data) ~= "table" then
    return nil, status_code, "Could not decode Hardcover OAuth response"
  end
  return data, status_code
end

local function runDismissable(request, message_or_dialog)
  local completed, raw = Trapper:dismissableRunInSubprocess(request, message_or_dialog, true)
  if not completed then
    return nil, nil, "cancelled"
  end
  return parseResponse(raw)
end

function OAuthClient:_requestDeviceCode()
  return postForm(OAUTH.DEVICE_ENDPOINT, {
    client_id = OAUTH.CLIENT_ID,
    scope = OAUTH.SCOPES,
  })
end

function OAuthClient:requestDeviceCode()
  local data, status_code, err = runDismissable(function()
    return self:_requestDeviceCode()
  end, _("Contacting Hardcover…"))
  if err then
    return nil, err
  end
  if status_code and status_code >= 200 and status_code < 300 and data and data.device_code then
    return data
  end
  return nil, (data and (data.error_description or data.error)) or err or "Could not start sign-in"
end

function OAuthClient:_pollToken(device_code)
  return postForm(OAUTH.TOKEN_ENDPOINT, {
    grant_type = "urn:ietf:params:oauth:grant-type:device_code",
    device_code = device_code,
    client_id = OAUTH.CLIENT_ID,
  })
end

function OAuthClient:pollToken(device_code, interval, dialog)
  local ffiutil = require("ffi/util")
  local data, status_code, err = runDismissable(function()
    ffiutil.sleep(interval)
    return self:_pollToken(device_code)
  end, dialog)
  if err then
    return nil, err
  end
  if status_code and status_code >= 200 and status_code < 300 then
    return data
  end
  -- authorization_pending and slow_down are normal HTTP 400 responses in
  -- the device flow; return their body so the dialog can keep polling.
  if data and data.error then
    return data
  end
  return nil, err or "OAuth token polling failed"
end

function OAuthClient:_refresh(refresh_token)
  return postForm(OAUTH.TOKEN_ENDPOINT, {
    grant_type = "refresh_token",
    refresh_token = refresh_token,
    client_id = OAUTH.CLIENT_ID,
  })
end

function OAuthClient:refresh(refresh_token)
  local data, status_code, err = runDismissable(function()
    return self:_refresh(refresh_token)
  end, false)
  if status_code and status_code >= 200 and status_code < 300 and data and data.access_token then
    return data
  end

  local oauth_error = data and data.error
  if status_code == 400 or status_code == 401
      or oauth_error == "invalid_grant"
      or oauth_error == "invalid_token"
      or oauth_error == "expired_token" then
    return nil, "rejected", data
  end
  return nil, err or (oauth_error and (data.error_description or oauth_error)) or "OAuth token refresh failed"
end

function OAuthClient:_revoke(token, token_type_hint)
  return postForm(OAUTH.REVOKE_ENDPOINT, {
    token = token,
    token_type_hint = token_type_hint,
    client_id = OAUTH.CLIENT_ID,
  })
end

function OAuthClient:revoke(token, token_type_hint)
  if not token or token == "" then
    return true
  end
  local _, status_code = runDismissable(function()
    return self:_revoke(token, token_type_hint)
  end, false)
  return status_code ~= nil and status_code >= 200 and status_code < 300
end

return OAuthClient
