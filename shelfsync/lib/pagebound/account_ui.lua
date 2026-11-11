local _ = require("gettext")

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local InfoMessage = require("ui/widget/infomessage")

local SETTING = require("shelfsync/lib/common/constants/settings")

local Account = {}

function Account.items(self)
  return {
    {
      text = _("How Pagebound login works"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[This plugin signs in with your Pagebound email and password through Firebase, then exchanges that session for a Pagebound API token. Firebase refresh tokens renew automatically. Your password is cached on this device -- encrypted at rest where possible -- so the plugin can re-authenticate if the refresh token stops working. If you change your Pagebound password, log in again here; "Log out" clears the credentials cached by this plugin.]]),
        })
      end,
      separator = true,
    },
    {
      text_func = function()
        local email = self.settings:readSetting(SETTING.PAGEBOUND.EMAIL)
        return (email and email ~= "") and _("Saved account: " .. email) or _("Log in")
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("Pagebound Login"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.PAGEBOUND.EMAIL) or "",
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
                    local info
                    local function showLoginStatus(text)
                      if info then UIManager:close(info) end
                      info = InfoMessage:new { text = text }
                      UIManager:show(info)
                    end

                    showLoginStatus(_("Checking your Pagebound credentials..."))
                    local ok, err = self.api:login(email, password, function(stage)
                      if stage == "pagebound_exchange" then
                        showLoginStatus(_("Connecting to Pagebound (the first connection can take a minute)..."))
                      end
                    end)
                    UIManager:close(info)

                    if ok then
                      menu_instance:updateItems()
                      UIManager:show(InfoMessage:new { text = _("Logged in to Pagebound") })
                    else
                      UIManager:show(InfoMessage:new {
                        text = _("Pagebound login failed: " .. (err or "unknown error")),
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
          text = _("Log out of Pagebound on this device?"),
          ok_callback = function()
            self.settings:updateSetting(SETTING.PAGEBOUND.EMAIL, "")
            self.settings:updateSetting(SETTING.PAGEBOUND.FIREBASE_ID_TOKEN, "")
            self.settings:updateSetting(SETTING.PAGEBOUND.REFRESH_TOKEN, "")
            self.settings:updateSetting(SETTING.PAGEBOUND.TOKEN_EXPIRES_AT, 0)
            self.settings:updateSetting(SETTING.PAGEBOUND.API_TOKEN, "")
            self.settings:updateSetting(SETTING.PAGEBOUND.PASSWORD_ENC, "")
            self.settings:updateSetting(SETTING.PAGEBOUND.PASSWORD_PLAIN, "")
            menu_instance:updateItems()
          end,
        })
      end,
    },
  }
end

return Account
