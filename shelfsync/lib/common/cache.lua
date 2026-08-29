local STATUS = require("shelfsync/lib/common/constants/status").STATUS

local Cache = {}
Cache.__index = Cache

function Cache:new(o) return setmetatable(o, self) end

function Cache:updateBookStatus(filename, status, ...)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  local result = self.api:updateUserBook(book_id, status, ...)
  self.state.book_status = result or {}

  if result and status == STATUS.FINISHED and self.provider then
    self.provider:onMarkedFinished(book_id, filename)
  end
end

function Cache:cacheUserBook()
  local filename = self.ui.document.file
  local status, errors = self.api:findUserBook(self.settings:getLinkedBookId(), self.user:getId())
  self.state.book_status = status or {}
  if status and status.page_count and status.page_count > 0 then
    local current_pages = self.settings:readBookSetting(filename, "pages")
    if not current_pages or current_pages == 0 then
      self.settings:updateBookSetting(filename, { pages = status.page_count })
    end
  end
  return errors
end

return Cache
