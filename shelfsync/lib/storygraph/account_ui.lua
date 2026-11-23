local _ = require("gettext")

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local InfoMessage = require("ui/widget/infomessage")

local SETTING = require("shelfsync/lib/common/constants/settings")

-- Falls back to shelfsync_config.lua's legacy cookies, same as api.lua's
-- get_headers(), so the menu doesn't show "(not set)" for a cookie that's
-- actually in use (e.g. carried over from a pre-Settings-menu install).
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local legacy_config = (config_ok and shelfsync_config.storygraph) or {}

local Account = {}

function Account.items(self)
  return {
    {
      text = _("Log in"),
      keep_menu_open = true,
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("StoryGraph Login"),
          fields = {
            {
              text = "",
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
                    local info = InfoMessage:new { text = _("Logging in to StoryGraph...") }
                    UIManager:show(info)
                    local ok, err = self.api:login(email, password)
                    UIManager:close(info)

                    if ok then
                      UIManager:show(InfoMessage:new { text = _("Logged in to StoryGraph") })
                    else
                      UIManager:show(InfoMessage:new {
                        text = _("StoryGraph login failed: " .. (err or "unknown error")),
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
      text = _("How to get your cookies"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Use "Log in" above to sign in with your email and password. Your password is not stored. If StoryGraph blocks the login request, you can import cookies from a browser session instead.

1. Log in to app.thestorygraph.com in a browser
2. Open dev tools (F12) > Application/Storage tab > Cookies > app.thestorygraph.com
3. Copy the value of '_storygraph_session' into "StoryGraph Session Cookie" below
4. Copy the value of 'remember_user_token' into "StoryGraph Remember Token" below (only present if you ticked "Remember me" at login)

The session cookie expires periodically (StoryGraph, not this plugin, decides when). You'll get a warning here when that happens - log in again or repeat these steps.]]),
        })
      end,
      separator = true,
    },
    {
      text = _("StoryGraph Session Cookie"),
      text_func = function()
        local set = self.settings:readSetting(SETTING.STORYGRAPH.SESSION_COOKIE)
        if not set or set == "" then set = legacy_config.session_cookie end
        return _("StoryGraph Session Cookie") .. (set and set ~= "" and _(" (set)") or _(" (not set)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("Value of the '_storygraph_session' cookie from a logged-in browser session. See \"How to get your cookies\" above."),
        })
      end,
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("StoryGraph Session Cookie"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.STORYGRAPH.SESSION_COOKIE) or legacy_config.session_cookie or "",
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
                  self.settings:updateSetting(SETTING.STORYGRAPH.SESSION_COOKIE, value)
                  UIManager:close(dialog)
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
      end,
    },
    {
      text = _("StoryGraph Remember Token"),
      text_func = function()
        local set = self.settings:readSetting(SETTING.STORYGRAPH.REMEMBER_TOKEN)
        if not set or set == "" then set = legacy_config.remember_user_token end
        return _("StoryGraph Remember Token") .. (set and set ~= "" and _(" (set)") or _(" (not set)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("Value of the 'remember_user_token' cookie from a logged-in browser session. See \"How to get your cookies\" above."),
        })
      end,
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("StoryGraph Remember Token"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.STORYGRAPH.REMEMBER_TOKEN) or legacy_config.remember_user_token or "",
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
                  self.settings:updateSetting(SETTING.STORYGRAPH.REMEMBER_TOKEN, value)
                  UIManager:close(dialog)
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
      end,
    }
  }
end

return Account
