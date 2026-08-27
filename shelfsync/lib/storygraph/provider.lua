-- wrapper around storygraph_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local Book = require("shelfsync/lib/common/book")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local STORYGRAPH = require("shelfsync/lib/storygraph/constants")

local StoryGraph = setmetatable({}, { __index = BaseProvider })
StoryGraph.__index = StoryGraph

function StoryGraph:showChangeEditionDialog(callback)
  local editions = self.api:findEditions(self.settings:getLinkedBookId(), self.user:getId())
  self.dialog_manager:buildSearchDialog(
    "Select edition",
    editions,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      if book.book_id ~= self.settings:getLinkedBookId() then
        local success = self.api:switchEdition(self.settings:getLinkedBookId(), book.book_id)
        if not success then
          self.dialog_manager:showError("Failed to switch edition on StoryGraph. Please try again.")
          return
        end
      end
      self:linkBook(book)
      if callback then
        callback(book)
      end
    end
  )
end

function StoryGraph:linkBook(book)
  local filename = self.ui.document.file

  -- 1. Fetch remote status (API handles redirection and audio filtering internally)
  local status = self.api:findUserBook(book.book_id) or {}

  -- 2. If the final resolved edition is Audio, fail the linking process
  if status.is_audio then
    logger.warn("StoryGraph: Cannot link to an Audio edition.")
    UIManager:show(InfoMessage:new{
      text = _("StoryGraph: Cannot link to an Audio edition. Please select a text-based edition.")
    })
    return false
  end

  -- 3. If findUserBook resolved to a different (non-audio) edition, use that ID instead
  if status.id and status.id ~= book.book_id then
    logger.info("StoryGraph: Redirecting link to your active edition: " .. status.id)
    book.book_id = status.id
    book.pages = status.book_num_of_pages or book.pages
  end

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "edition_format", "pages", "title" })

  local new_settings = {
    book_id = book.book_id,
    edition_format = status.edition_format or Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  -- 3. Save link information
  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  -- 4. Auto-Add to Library if no status was found on ANY edition
  if not self.state.book_status.status_id then
    logger.info("StoryGraph: Book has no status on any edition, adding to Currently Reading automatically")
    local added = self.api:updateUserBook(book.book_id, STORYGRAPH.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      -- The book stays linked locally either way (settings already saved
      -- above), but without this the failure was completely silent -- the
      -- book would just sit unsynced until the status-mismatch warning
      -- eventually caught it much later, with no link back to the cause.
      logger.warn("StoryGraph: Failed to automatically mark book as Currently Reading on StoryGraph")
      self.state.book_status = added or {}
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't automatically mark the book as Currently Reading on StoryGraph. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

-- Remote progress in `update_type`'s unit, read from a cached book_status
-- table (e.g. self.state.book_status), used by SyncEngine to skip a
-- background write that would move progress backward.
function StoryGraph:getRemoteProgress(status, update_type)
  if update_type == "pages" then
    return tonumber(status and status.last_reached_pages) or 0
  end
  return tonumber(status and status.percent_finished) or 0
end

-- Overall remote completion percent (0-100), or nil if unknown. Used by
-- "Jump to position" and to seed the note dialog's remote-percent hint.
function StoryGraph:getRemotePercent(status)
  return tonumber(status and status.last_reached_percent) or 0
end

-- Writes a progress update to StoryGraph and returns the refreshed status, or
-- nil plus an error reason on failure. Also auto-marks the book Finished when
-- the write pushes it to 100% while still Currently Reading.
function StoryGraph:pushProgress(current_read, value, update_type, filename)
  if not current_read then
    return nil, "No active reading session found on StoryGraph"
  end

  local result = self.api:updatePage(current_read.id, value, current_read.started_at, update_type)
  if not result then
    return nil
  end

  if (tonumber(result.percent_finished) or 0) >= 100 and result.status_id == STORYGRAPH.STATUS.READING then
    local book_id = self.settings:readBookSetting(filename, "book_id")
    if book_id then
      local finished = self.api:updateUserBook(book_id, STORYGRAPH.STATUS.FINISHED)
      if finished then
        result = finished
      end
    end
  end

  return result
end

return StoryGraph
