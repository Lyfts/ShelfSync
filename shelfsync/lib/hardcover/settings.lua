local BaseSettings = require("shelfsync/lib/common/base_settings")
local os = require("os")
local SETTING = require("shelfsync/lib/common/constants/settings")

local HardcoverSettings = setmetatable({}, { __index = BaseSettings })
HardcoverSettings.__index = HardcoverSettings

function HardcoverSettings:new(path, ui, shared)
  return BaseSettings.new(self, path, ui, "hardcover", shared)
end

-- Unlike StoryGraph, Hardcover has a real book/edition distinction: a book
-- can be linked without a specific edition chosen yet.
function HardcoverSettings:getLinkedBookId()
  return self:readBookSetting(self:getFilePath(), "book_id")
end

function HardcoverSettings:getLinkedEditionId()
  return self:readBookSetting(self:getFilePath(), "edition_id")
end

function HardcoverSettings:editionLinked()
  return self:getLinkedEditionId() ~= nil
end

function HardcoverSettings:readLinked()
  return self:readBookSetting(self:getFilePath(), "read_id") ~= nil
end

function HardcoverSettings:hasOAuthSession()
  local refresh_token = self:readSetting(SETTING.HARDCOVER.REFRESH_TOKEN)
  local access_token = self:readSetting(SETTING.HARDCOVER.ACCESS_TOKEN)
  return (refresh_token and refresh_token ~= "") or (access_token and access_token ~= "") or false
end

function HardcoverSettings:isOAuthTokenExpired(leeway)
  leeway = leeway or 60
  local access_token = self:readSetting(SETTING.HARDCOVER.ACCESS_TOKEN)
  if not access_token or access_token == "" then
    return true
  end

  local expires_at = tonumber(self:readSetting(SETTING.HARDCOVER.TOKEN_EXPIRES_AT))
  if not expires_at then
    return false
  end
  return os.time() >= (expires_at - leeway)
end

function HardcoverSettings:saveOAuthTokens(tokens, identity_changed)
  if identity_changed then
    -- User:getId() caches the previous credential's account id. Force it to
    -- resolve again after a fresh OAuth login or account switch.
    self:clearOAuthSession()
  end

  self:updateSetting(SETTING.HARDCOVER.ACCESS_TOKEN, tokens.access_token)
  if tokens.refresh_token then
    self:updateSetting(SETTING.HARDCOVER.REFRESH_TOKEN, tokens.refresh_token)
  end
  if tokens.expires_in then
    self:updateSetting(
      SETTING.HARDCOVER.TOKEN_EXPIRES_AT,
      os.time() + (tonumber(tokens.expires_in) or 0)
    )
  end
end

function HardcoverSettings:clearOAuthSession()
  self:updateSetting(SETTING.HARDCOVER.ACCESS_TOKEN, nil)
  self:updateSetting(SETTING.HARDCOVER.REFRESH_TOKEN, nil)
  self:updateSetting(SETTING.HARDCOVER.TOKEN_EXPIRES_AT, nil)
  self:updateSetting(SETTING.USER_ID, nil)
end

return HardcoverSettings
