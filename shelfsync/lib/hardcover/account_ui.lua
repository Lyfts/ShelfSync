local _ = require("gettext")

local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")

local SETTING = require("shelfsync/lib/common/constants/settings")

-- Falls back to shelfsync_config.lua's legacy token, same as api.lua's
-- get_headers(), so the menu doesn't show "(not set)" for a token that's
-- actually in use (e.g. carried over from a pre-Settings-menu install).
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local legacy_config = (config_ok and shelfsync_config.hardcover) or {}

local Account = {}

function Account.items(self)
  return {
    {
      text = _("How Hardcover authentication works"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Sign in with Hardcover using the device code shown by ShelfSync.
OAuth is used whenever you are signed in. The API token below is used as a fallback when OAuth is signed out.

After adding an OAuth permission, sign in again here so this device receives an updated grant.

To use an API token instead, create one at hardcover.app/account/api and paste it below. The token remains on this device and can be regenerated from the same page.]]),
        })
      end,
      separator = true,
    },
    {
      text_func = function()
        return self.settings:hasOAuthSession()
          and _("Signed in with Hardcover (OAuth)")
          or _("Sign in with Hardcover (OAuth)")
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        local DeviceAuthDialog = require("shelfsync/lib/hardcover/device_auth_dialog")
        DeviceAuthDialog:new():show(function(tokens)
          if self.api:saveOAuthTokens(tokens) then
            menu_instance:updateItems()
            UIManager:show(InfoMessage:new { text = _("Signed in to Hardcover") })
          else
            UIManager:show(InfoMessage:new {
              text = _("Hardcover did not return an access token"),
              icon = "notice-warning",
            })
          end
        end, function(error_message)
          UIManager:show(InfoMessage:new {
            text = _("Hardcover sign-in failed: " .. tostring(error_message)),
            icon = "notice-warning",
          })
        end)
      end,
      separator = true,
    },
    {
      text = _("Sign out of Hardcover OAuth"),
      enabled_func = function()
        return self.settings:hasOAuthSession()
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = _("Sign out of Hardcover OAuth on this device? Your API token fallback will be kept."),
          ok_callback = function()
            self.api:logoutOAuth()
            menu_instance:updateItems()
            UIManager:show(InfoMessage:new {
              text = self.api:hasCredential()
                  and _("Signed out of OAuth. The configured API token is now in use.")
                or _("Signed out of Hardcover"),
            })
          end,
        })
      end,
      separator = true,
    },
    {
      text_func = function()
        local set = self.settings:readSetting(SETTING.HARDCOVER.API_TOKEN)
        if not set or set == "" then set = legacy_config.token end
        return _("Hardcover API Token fallback") .. (set and set ~= "" and _(" (set)") or _(" (not set)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("Used when OAuth is signed out. See \"How Hardcover authentication works\" above."),
        })
      end,
      callback = function(menu_instance)
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("Hardcover API Token fallback"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.HARDCOVER.API_TOKEN) or legacy_config.token or "",
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
                text = _("Save"),
                callback = function()
                  local value = dialog:getFields()[1]
                  self.settings:updateSetting(SETTING.HARDCOVER.API_TOKEN, value)
                  UIManager:close(dialog)
                  menu_instance:updateItems()
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
      end,
    },
  }
end

return Account
