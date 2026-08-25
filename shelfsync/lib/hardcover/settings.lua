local BaseSettings = require("shelfsync/lib/common/base_settings")

local HardcoverSettings = setmetatable({}, { __index = BaseSettings })
HardcoverSettings.__index = HardcoverSettings

function HardcoverSettings:new(path, ui)
  return BaseSettings.new(self, path, ui, "hardcover")
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

return HardcoverSettings
