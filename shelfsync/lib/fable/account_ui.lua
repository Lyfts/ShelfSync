local _ = require("gettext")

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local InfoMessage = require("ui/widget/infomessage")

local SETTING = require("shelfsync/lib/common/constants/settings")

local Account = {}

function Account.items(self)
  return {
    {
      text = _("How Fable login works"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[This plugin logs in directly with your Fable email and password using Firebase authentication.

The access/refresh token pair Fable's own login returns (the same thing its official app keeps) refreshes itself automatically from then on. Your password is also cached on this device -- encrypted at rest where possible -- so that if the refresh token itself ever dies, the plugin can silently log back in instead of asking you to retype it. If you change your Fable password, just log in again here once; "Log out" below clears everything this plugin has cached.]]),
        })
      end,
      separator = true,
    },
    {
      text_func = function()
        local email = self.settings:readSetting(SETTING.FABLE.EMAIL)
        return (email and email ~= "") and _("Logged in as: " .. email) or _("Log in")
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("Fable Login"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.FABLE.EMAIL) or "",
              hint = _("Email"),
            },
            {
              text = "",
              hint = _("Password"),
              text_type = "password",
            },
          },
          buttons = {
            {
              {
                text = _("Cancel"),
                callback = function()
                  UIManager:close(dialog)
                end,
              },
              {
                text = _("Log in"),
                callback = function()
                  local fields = dialog:getFields()
                  local email, password = fields[1], fields[2]
                  UIManager:close(dialog)

                  Trapper:wrap(function()
                    local info = InfoMessage:new { text = _("Logging in to Fable...") }
                    UIManager:show(info)
                    local ok, err = self.api:login(email, password)
                    UIManager:close(info)

                    if ok then
                      menu_instance:updateItems()
                      UIManager:show(InfoMessage:new { text = _("Logged in to Fable") })
                    else
                      UIManager:show(InfoMessage:new {
                        text = _("Fable login failed: " .. (err or "unknown error")),
                        icon = "notice-warning",
                      })
                    end
                  end)
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
      end,
    },
    {
      text = _("Log out"),
      enabled_func = function()
        return self.api:hasCredential()
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = _("Log out of Fable on this device?"),
          ok_callback = function()
            self.settings:updateSetting(SETTING.FABLE.EMAIL, "")
            self.settings:updateSetting(SETTING.FABLE.ID_TOKEN, "")
            self.settings:updateSetting(SETTING.FABLE.REFRESH_TOKEN, "")
            self.settings:updateSetting(SETTING.FABLE.TOKEN_EXPIRES_AT, 0)
            self.settings:updateSetting(SETTING.FABLE.PASSWORD_ENC, "")
            self.settings:updateSetting(SETTING.FABLE.PASSWORD_PLAIN, "")
            menu_instance:updateItems()
          end,
        })
      end,
    },
  }
end

return Account
