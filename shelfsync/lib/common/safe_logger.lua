-- Route ShelfSync logs through this module so credentials and user content
-- are redacted before they reach KOReader's persistent crash log.
local native_logger = require("logger")

local SafeLogger = {}
local redacted = "[REDACTED]"

local sensitive_segments = {
  authorization = true,
  author = true,
  body = true,
  comment = true,
  content = true,
  cookie = true,
  description = true,
  csrf = true,
  email = true,
  entry = true,
  message = true,
  note = true,
  payload = true,
  password = true,
  quote = true,
  query = true,
  review = true,
  search = true,
  secret = true,
  session = true,
  term = true,
  terms = true,
  text = true,
  title = true,
  token = true,
  username = true,
}

local function is_sensitive_key(key)
  key = key:lower()
  key = key:gsub("%%5[bB]", "["):gsub("%%5[dD]", "]")
  key = key:gsub("%[", "_"):gsub("%]", "")
  key = key:gsub("[^%w_%-]", "_")
  if key:match("_length$") or key:match("_present$") or key:match("_count$")
      or key:match("_type$") then
    return false
  end
  for segment in key:gmatch("[^_%-]+") do
    if sensitive_segments[segment] then
      return true
    end
  end
  return false
end

local function is_body_label(value)
  local lower = value:lower()
  return lower:match("post%s+body%s*:%s*$") ~= nil
    or lower:match("request%s+body%s*:%s*$") ~= nil
    or lower:match("body%s*:%s*$") ~= nil
end

local function expects_sensitive_value(value)
  local key = value:match("([%w_%%%-]+)%s*[=:]%s*[\"']?%s*$")
  return key and is_sensitive_key(key) or false
end

local function sanitize_string(value)
  -- An HTTP query can contain a full search phrase, so never retain its value.
  value = value:gsub("%?[^%s\"'<>]+", "?[REDACTED]")

  -- A response fragment can include account data, form values, or CSRF
  -- tokens. Keep its size for debugging and discard the content.
  if value:find("</?[%a][^>]*>") then
    return "[HTML redacted; length=" .. #value .. "]"
  end

  -- Protect accidental whole-body logging, including the common two-argument
  -- logger form: logger.info("POST Body:", body).
  value = value:gsub("([Pp][Oo][Ss][Tt]%s+[Bb][Oo][Dd][Yy]%s*:%s*)[%s%S]+", "%1" .. redacted)
  value = value:gsub("([Rr][Ee][Qq][Uu][Ee][Ss][Tt]%s+[Bb][Oo][Dd][Yy]%s*:%s*)[%s%S]+", "%1" .. redacted)

  -- Redact values in query/form/log fields such as csrf=..., note=..., and
  -- JSON-style "authenticity_token": "...". This also handles encoded
  -- bracketed names such as user_status%5Bbody%5D.
  value = value:gsub("([\"']?)([^%s&;,=\"']+)([\"']?)(%s*[=:]%s*[\"']?)([^%s&;,\"'<>]+)",
    function(leading_quote, key, trailing_quote, separator, field_value)
      if is_sensitive_key(key) then
        return leading_quote .. key .. trailing_quote .. separator .. redacted
      end
      return leading_quote .. key .. trailing_quote .. separator .. field_value
    end)

  return value
end

local function sanitize_value(value, seen, depth)
  local value_type = type(value)
  if value_type == "string" then
    return sanitize_string(value)
  end
  if value_type ~= "table" then
    return value
  end

  if depth >= 5 then
    return "[table omitted]"
  end
  if seen[value] then
    return "[cycle]"
  end
  seen[value] = true

  local safe_table = {}
  for key, field_value in pairs(value) do
    if type(key) == "string" and is_sensitive_key(key) then
      safe_table[key] = redacted
    else
      safe_table[key] = sanitize_value(field_value, seen, depth + 1)
    end
  end
  seen[value] = nil
  return safe_table
end

local function wrap_log_method(method_name)
  local native_method = native_logger[method_name]
  if type(native_method) ~= "function" then
    return native_method
  end

  return function(...)
    local count = select("#", ...)
    local args = {}
    local redact_next = false
    for index = 1, count do
      local value = select(index, ...)
      if redact_next then
        args[index] = redacted
      else
        args[index] = sanitize_value(value, {}, 0)
      end
      redact_next = type(value) == "string"
        and (is_body_label(value) or expects_sensitive_value(value))
    end
    return native_method(table.unpack(args, 1, count))
  end
end

setmetatable(SafeLogger, {
  __index = function(self, method_name)
    local wrapped = wrap_log_method(method_name)
    rawset(self, method_name, wrapped)
    return wrapped
  end,
})

return SafeLogger
