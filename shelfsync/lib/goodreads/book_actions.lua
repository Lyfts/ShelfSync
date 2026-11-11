local _ = require("gettext")
local math = require("math")

local T = require("ffi/util").template

local GOODREADS = require("shelfsync/lib/goodreads/constants")

local BookActions = {}

function BookActions.items(self)
  local items = {}

  local status = self.state.book_status.status_id

  -- Update progress: only when NOT read, DNF, removed, or want to read
  if status and status ~= GOODREADS.STATUS.FINISHED and status ~= GOODREADS.STATUS.DNF and status ~= GOODREADS.STATUS.TO_READ then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.provider:getRemotePercent(self.state.book_status) or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

  return items
end

return BookActions
