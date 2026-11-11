local _ = require("gettext")
local math = require("math")
local os = require("os")

local T = require("ffi/util").template

local UIManager = require("ui/uimanager")

local UpdateDoubleSpinWidget = require("shelfsync/lib/common/ui/update_double_spin_widget")
local SpinWidget = require("ui/widget/spinwidget")

local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local ICON = require("shelfsync/lib/common/constants/icons")

local BookActions = {}

local privacy_labels = {
  [HARDCOVER.PRIVACY.PUBLIC] = "Public",
  [HARDCOVER.PRIVACY.FOLLOWS] = "Follows",
  [HARDCOVER.PRIVACY.PRIVATE] = "Private"
}

function BookActions.visibilityItems(self)
  return {
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PUBLIC]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PUBLIC
      end,
      callback = function()
        self.provider:changeBookVisibility(HARDCOVER.PRIVACY.PUBLIC)
      end,
      radio = true,
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.FOLLOWS]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.FOLLOWS
      end,
      callback = function()
        self.provider:changeBookVisibility(HARDCOVER.PRIVACY.FOLLOWS)
      end,
      radio = true
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PRIVATE]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PRIVATE
      end,
      callback = function()
        self.provider:changeBookVisibility(HARDCOVER.PRIVACY.PRIVATE)
      end,
      radio = true
    },
  }
end

function BookActions.items(self)
  local items = {
    {
      text_func = function()
        local reads = self.state.book_status.user_book_reads
        local current_page = reads and reads[#reads] and reads[#reads].progress_pages or 0
        local max_pages = self.settings:pages()

        if not max_pages then
          max_pages = "???"
        end

        return T(_("Update page: %1 of %2"), current_page, max_pages)
      end,
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id == HARDCOVER.STATUS.READING and self.settings:pages()
      end,
      callback = function(menu_instance)
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local last_hardcover_page = current_read and current_read.progress_pages or 0

        local document_page = self.ui:getCurrentPage()
        local document_pages = self.ui.document:getPageCount()

        local remote_pages = self.settings:pages()
        local mapped_page = self.page_mapper:getMappedPage(document_page, document_pages, remote_pages)

        local left_text = "Edition"
        if last_hardcover_page > 0 then
          left_text = left_text .. ": was " .. last_hardcover_page
        end

        local spinner = UpdateDoubleSpinWidget:new {
          ok_always_enabled = true,

          left_text = left_text,
          left_value = mapped_page,
          left_min = 0,
          left_max = remote_pages,
          left_step = 1,
          left_hold_step = 20,

          right_text = "Local page",
          right_value = document_page,
          right_min = 0,
          right_max = document_pages,
          right_step = 1,
          right_hold_step = 20,

          update_callback = function(new_edition_page, new_document_page, edition_page_changed)
            if edition_page_changed then
              local new_mapped_page = self.page_mapper:getUnmappedPage(new_edition_page, document_pages, remote_pages)
              return new_edition_page, new_mapped_page
            else
              local new_mapped_page = self.page_mapper:getMappedPage(new_document_page, document_pages, remote_pages)
              return new_mapped_page, new_document_page
            end
          end,
          ok_text = _("Set page"),
          title_text = _("Set current page"),

          callback = function(edition_page, _document_page)
            local result

            if current_read then
              result = self.api:updatePage(current_read.id, current_read.edition_id, edition_page,
                current_read.started_at)
            else
              local start_date = os.date("%Y-%m-%d")
              result = self.api:createRead(self.state.book_status.id, self.state.book_status.edition_id, edition_page,
                start_date)
            end

            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError("Page could not be saved")
            end
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = _("Add a note"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      callback = function()
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local current_page = current_read and current_read.progress_pages or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          nil,
          "note"
        )
      end,
      keep_menu_open = true
    },
    {
      text_func = function()
        local text
        if self.state.book_status.rating then
          text = "Update rating"
          local whole_star = math.floor(self.state.book_status.rating)
          local star_string = string.rep(ICON.STAR, whole_star)
          if self.state.book_status.rating - whole_star > 0 then
            star_string = star_string .. ICON.HALF_STAR
          end
          text = text .. ": " .. star_string
        else
          text = "Set rating"
        end

        return _(text)
      end,
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      callback = function(menu_instance)
        local rating = self.state.book_status.rating

        local spinner = SpinWidget:new {
          ok_always_enabled = rating == nil,
          value = rating or 2.5,
          value_min = 0,
          value_max = 5,
          value_step = 0.5,
          value_hold_step = 2,
          precision = "%.1f",
          ok_text = _("Save"),
          title_text = _("Set Rating"),
          callback = function(spin)
            local result = self.api:updateRating(self.state.book_status.id, spin.value)
            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError("Rating could not be saved")
            end
          end
        }
        UIManager:show(spinner)
      end,
      hold_callback = function(menu_instance)
        local result = self.api:updateRating(self.state.book_status.id, 0)
        if result then
          self.state.book_status = result
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true
    },
    {
      text = _("Set status visibility"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      sub_item_table_func = function()
        return BookActions.visibilityItems(self)
      end,
    },
  }

  return items
end

return BookActions
