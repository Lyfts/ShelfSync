local http = require("socket.http")
local ltn12 = require("ltn12")

local VERSION = require("shelfsync_version")

local META_URL = "https://raw.githubusercontent.com/Lyfts/ShelfSync/main/_meta.lua"

local Github = {}

-- Pulls a single "key = value" field out of a fetched _meta.lua by line,
-- anchored to the start of the (trimmed) line so e.g. a "version" lookup
-- can't accidentally match inside "api_version". Deliberately not `load()`-ed
-- as code: this is untrusted content fetched over the network, and executing
-- it would hand code execution to whoever can push to that file.
local function extractField(source, key)
  for line in source:gmatch("[^\r\n]+") do
    local str_val = line:match('^%s*' .. key .. '%s*=%s*"(.-)"%s*,?%s*$')
    if str_val then return str_val end

    local num_val = line:match('^%s*' .. key .. '%s*=%s*(%d+)%s*,?%s*$')
    if num_val then return tonumber(num_val) end
  end
end

function Github:fetchVersionInfo()
  local responseBody = {}
  local res, code, responseHeaders = http.request {
    url = META_URL,
    sink = ltn12.sink.table(responseBody),
  }

  if code == 200 then
    local source = table.concat(responseBody)
    local plugin_version = extractField(source, "version")
    if not plugin_version then return nil end

    return {
      plugin_version = plugin_version,
      api_version = extractField(source, "api_version"),
    }
  end
end

function Github:isNewer(version_str)
  local index = 1
  for str in string.gmatch(version_str, "([^.]+)") do
    local part = tonumber(str)
    if not part or not VERSION[index] then break end

    if part < VERSION[index] then
      return false
    elseif part > VERSION[index] then
      return true
    end
    index = index + 1
  end
  return false
end

return Github
