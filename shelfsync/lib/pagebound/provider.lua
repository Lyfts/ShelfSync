local _ = require("gettext")
local logger = require("shelfsync/lib/common/safe_logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local Book = require("shelfsync/lib/common/book")
local PAGEBOUND = require("shelfsync/lib/pagebound/constants")

local Pagebound = setmetatable({
  allows_new_read = true,
}, { __index = BaseProvider })
Pagebound.__index = Pagebound

function Pagebound:linkBook(book, link_method)
  local filename = self.ui.document.file
  local book_uuid = book.book_uuid or book.uuid
  local status, lookup_error = self.api:findUserBook(book.book_id, nil, book_uuid)
  status = status or {}
  local pages = tonumber(book.pages) or tonumber(status.page_count)
  book.pages = pages

  local delete = self:_deletedKeys(book, { "book_id", "book_uuid", "edition_id", "edition_format", "pages", "title" })
  local new_settings = {
    book_id = tostring(book.book_id),
    book_uuid = book_uuid,
    pages = pages,
    title = book.title,
    link_method = link_method,
    _delete = delete,
  }

  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  -- A failed lookup isn't proof the book is missing from the library, and
  -- adding it could replace a status it already has (e.g. Finished).
  if lookup_error then
    logger.warn("Pagebound: Couldn't check the book's status, not adding it to Currently Reading: " .. tostring(lookup_error))
    UIManager:show(InfoMessage:new {
      text = _("Linked, but couldn't check the book's status on Pagebound, so it wasn't added to Currently Reading automatically. Use \"Update status\" to set it manually."),
      icon = "notice-warning",
    })
  elseif not status.status_id then
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
      return math.floor(page * 100 / total)
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
      return math.floor(page * 100 / total)
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

  local status = self.state.book_status or {}
  local total_pages = tonumber(status.total_page_count or status.page_count)
  if not total_pages or total_pages <= 0 then
    total_pages = tonumber(self.settings:pages())
  end
  local current_page
  if update_type == "pages" then
    current_page = tonumber(value)
  elseif self.ui and self.ui.document and self.page_mapper then
    local local_page = self.ui:getCurrentPage()
    local document_pages = self.ui.document:getPageCount()
    if local_page and document_pages and document_pages > 0 then
      current_page = self.page_mapper:getMappedPage(local_page, document_pages, total_pages)
    end
  end

  local result, err = self.api:updateProgress(
    book_id,
    status,
    current_read,
    value,
    update_type,
    current_page
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

-- Pagebound accepts half-star ratings. Round the composer's quarter-stars
-- down and submit the rating and optional text through its native review API.
function Pagebound:submitReview(filename, rating, text)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return false, "No linked book found on Pagebound"
  end

  local cache_error = self.cache and self.cache:cacheUserBook()
  if cache_error then
    return false, cache_error
  end

  local user_book_id = self.state.book_status and self.state.book_status.user_book_id
  if not user_book_id then
    return false, "No Pagebound reading-list entry found for this book"
  end

  local review_rating = rating and rating > 0 and (math.floor(rating * 2) / 2) or nil
  local review_text = (text and text:match("%S")) and text or nil
  if not review_rating and not review_text then
    return false, "No rating or review text supplied"
  end

  local ok, err = self.api:setReview(book_id, user_book_id, review_rating, review_text)
  return ok == true, err
end

return Pagebound
