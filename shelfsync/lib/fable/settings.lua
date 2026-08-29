local BaseSettings = require("shelfsync/lib/common/base_settings")

local FableSettings = setmetatable({}, { __index = BaseSettings })
FableSettings.__index = FableSettings

function FableSettings:new(path, ui, shared)
  return BaseSettings.new(self, path, ui, "fable", shared)
end

-- Fable has no edition-picker UI in this plugin (see provider.lua's
-- linkBook, which resolves a page count automatically instead of exposing a
-- "change edition" menu like Hardcover's), so book_id doubles as
-- edition_id here, same as StoryGraph/Goodreads.
function FableSettings:getLinkedBookId()
  return self:readBookSetting(self:getFilePath(), "book_id")
end

function FableSettings:getLinkedEditionId()
  return self:getLinkedBookId()
end

return FableSettings
