local BaseSettings = require("shelfsync/lib/common/base_settings")

local PageboundSettings = setmetatable({}, { __index = BaseSettings })
PageboundSettings.__index = PageboundSettings

function PageboundSettings:new(path, ui, shared)
  return BaseSettings.new(self, path, ui, "pagebound", shared)
end

function PageboundSettings:getLinkedBookId()
  return self:readBookSetting(self:getFilePath(), "book_id")
end

function PageboundSettings:getLinkedEditionId()
  return self:getLinkedBookId()
end

return PageboundSettings
