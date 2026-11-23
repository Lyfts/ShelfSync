local _ = require("gettext")
local math = require("math")

local UIManager = require("ui/uimanager")
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
