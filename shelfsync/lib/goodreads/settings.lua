local BaseSettings = require("shelfsync/lib/common/base_settings")

local GoodreadsSettings = setmetatable({}, { __index = BaseSettings })
GoodreadsSettings.__index = GoodreadsSettings

function GoodreadsSettings:new(path, ui, shared)
  return BaseSettings.new(self, path, ui, "goodreads", shared)
end

-- Goodreads doesn't expose a separate edition id from the book id it links
-- to (no edition-switching support), so book_id and edition_id are treated
-- as interchangeable here, same as StoryGraph.
function GoodreadsSettings:getLinkedBookId()
  local file = self:getFilePath()
  return self:readBookSetting(file, "book_id") or self:readBookSetting(file, "edition_id")
end

function GoodreadsSettings:getLinkedEditionId()
  return self:getLinkedBookId()
end

return GoodreadsSettings
