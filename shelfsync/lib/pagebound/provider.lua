local _ = require("gettext")
local logger = require("logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local Book = require("shelfsync/lib/common/book")
local PAGEBOUND = require("shelfsync/lib/pagebound/constants")

local Pagebound = setmetatable({
  allows_new_read = true,
}, { __index = BaseProvider })
Pagebound.__index = Pagebound

function Pagebound:linkBook(book)
  local filename = self.ui.document.file
  local book_uuid = book.book_uuid or book.uuid
  local status = self.api:findUserBook(book.book_id, nil, book_uuid) or {}
  local pages = tonumber(book.pages) or tonumber(status.page_count)
  book.pages = pages

  local delete = self:_deletedKeys(book, { "book_id", "book_uuid", "edition_id", "edition_format", "pages", "title" })
  local new_settings = {
    book_id = tostring(book.book_id),
    book_uuid = book_uuid,
    pages = pages,
    title = book.title,
    _delete = delete,
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  if not status.status_id then
    logger.info("Pagebound: Book is not in the library, adding it to Currently Reading")
    local added = self.api:updateUserBook(book.book_id, PAGEBOUND.STATUS.READING, pages, book_uuid)
    if added and added.status_id then
      self.state.book_status = added
    else
      logger.warn("Pagebound: Failed to add book as Currently Reading")
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't add the book to Currently Reading on Pagebound. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

function Pagebound:getRemoteProgress(status, update_type)
  if update_type == "pages" then
    return tonumber(status and status.current_page) or 0
  end

  local method = status and status.progress_method
  if method == "percent" then
    return tonumber(status and status.progress) or 0
  end
  if method == "pages" or tonumber(status and status.current_page) ~= nil then
    local page = tonumber(status.current_page)
    local total = tonumber(status.total_page_count or status.page_count)
    if page and total and total > 0 then
      return math.floor(page * 100 / total + 0.5)
    end
    return 0
  end

  return tonumber(status and status.progress) or 0
end

function Pagebound:getRemotePercent(status)
  local method = status and status.progress_method
  if method == "percent" then
    return tonumber(status and status.progress)
  end
  if method == "pages" or tonumber(status and status.current_page) ~= nil then
    local page = tonumber(status.current_page)
    local total = tonumber(status.total_page_count or status.page_count)
    if page and total and total > 0 then
      return math.floor(page * 100 / total + 0.5)
    end
    return nil
  end

  return tonumber(status and status.progress)
end

function Pagebound:pushProgress(current_read, value, update_type, filename)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return nil, "No linked book found on Pagebound"
  end

  local result, err = self.api:updateProgress(
    book_id,
    self.state.book_status,
    current_read,
    value,
    update_type
  )
  if not result then
    return nil, err
  end

  local finished
  if update_type == "pages" then
    local pages = tonumber(result.total_page_count or result.page_count or self.settings:pages())
    finished = pages and pages > 0 and value >= pages
  else
    finished = value >= 100
  end

  if result.status_id == PAGEBOUND.STATUS.READING and finished then
    local completed = self.api:updateUserBook(book_id, PAGEBOUND.STATUS.FINISHED, result.total_page_count)
    if completed then
      result = completed
    end
  end

  return result
end

return Pagebound
