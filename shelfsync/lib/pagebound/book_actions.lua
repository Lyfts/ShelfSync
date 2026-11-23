local _ = require("gettext")

local BookActions = {}

function BookActions.items(self)
  return {
    {
      text = _("Add forum note"),
      enabled_func = function() return self:isActive() and self.settings:bookLinked() end,
      callback = function()
        -- note_only hides the progress editor; the note still saves the
        -- current position so the forum post lands at the right point.
        local remote_percent = self.provider:getRemotePercent(self.state.book_status) or 0
        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          self.ui:getCurrentPage(),
          self.settings:pages(),
          nil, remote_percent, "note", true
        )
      end,
      keep_menu_open = true,
    },
  }
end

return BookActions
