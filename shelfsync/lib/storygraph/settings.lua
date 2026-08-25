local BaseSettings = require("shelfsync/lib/common/base_settings")

local StoryGraphSettings = setmetatable({}, { __index = BaseSettings })
StoryGraphSettings.__index = StoryGraphSettings

function StoryGraphSettings:new(path, ui, shared)
  return BaseSettings.new(self, path, ui, "storygraph", shared)
end

-- StoryGraph doesn't expose a separate edition id from the book id it links
-- to (linking IS the edition, via linkBook/switchEdition), so book_id and
-- edition_id are treated as interchangeable here.
function StoryGraphSettings:getLinkedBookId()
  local file = self:getFilePath()
  return self:readBookSetting(file, "book_id") or self:readBookSetting(file, "edition_id")
end

function StoryGraphSettings:getLinkedEditionId()
  return self:getLinkedBookId()
end

return StoryGraphSettings
