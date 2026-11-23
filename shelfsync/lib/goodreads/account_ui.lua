local _ = require("gettext")

local T = require("ffi/util").template

local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")

local SETTING = require("shelfsync/lib/common/constants/settings")

-- Falls back to shelfsync_config.lua's legacy cookie, same as api.lua's
-- get_headers(), so the menu doesn't show "(not set)" for a cookie that's
-- actually in use (e.g. carried over from a pre-Settings-menu install).
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local legacy_config = (config_ok and shelfsync_config.goodreads) or {}

local Account = {}

function Account.items(self)
  return {
    {
      text = _("How to get your cookie"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Goodreads has no login API, so this plugin reuses your browser's session cookie.

1. Log in to goodreads.com in a browser
2. Open dev tools (F12) > Network tab, then reload the page
3. Click any request to www.goodreads.com and find "Cookie" under Request Headers
4. Right-click it > Copy Value, and paste the whole thing into "Goodreads Cookie" below

Goodreads accounts are linked through Amazon, so this cookie is a large bundle rather than a single value -- copy the entire header, not just one part of it. It expires periodically; you'll get a warning here when that happens, just repeat these steps.]]),
        })
      end,
      separator = true,
    },
    {
      text = _("Goodreads Cookie"),
      text_func = function()
        local set = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE)
        if not set or set == "" then set = legacy_config.cookie end
        return _("Goodreads Cookie") .. (set and set ~= "" and _(" (set)") or _(" (not set)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("The full 'Cookie' request header value from a logged-in browser session. See \"How to get your cookie\" above."),
        })
      end,
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("Goodreads Cookie"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE) or legacy_config.cookie or "",
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
                  self.settings:updateSetting(SETTING.GOODREADS.SESSION_COOKIE, value)
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
      text = _("Test connection"),
      keep_menu_open = true,
      separator = true,
      help_text = _([[Check that your Goodreads session works. If a Cookie Auto-Refresh URL is set,
the plugin tries it when the cookie is missing or expired.]]),
      callback = function()
        local loading = InfoMessage:new { text = _("Testing Goodreads connection…") }
        UIManager:show(loading)

        local function show_result(result)
          local text
          local icon
          if result and result.ok then
            if result.cookie_refreshed then
              text = _("Goodreads: connection OK (cookie refreshed)")
            elseif result.user_id then
              text = T(_("Goodreads: connection OK (user %1)"), tostring(result.user_id))
            else
              text = _("Goodreads: connection OK")
            end
          else
            icon = "notice-warning"
            local err = result and result.error
            if err == "no_network" or err == "Network not connected" then
              text = _("Goodreads: no network connection")
            elseif err == "no_cookies" then
              text = _("Goodreads: no session cookie or Cookie Auto-Refresh URL is configured")
            elseif err == "session_expired" or err == "Unauthorized" then
              text = _("Goodreads: session expired. Replace the cookie or check the configured refresher.")
            elseif err == "waf_challenge" then
              text = _("Goodreads: AWS WAF blocked the request. The cookie refresher could not clear the challenge.")
            elseif err == "unexpected_response" then
              text = _("Goodreads: could not confirm an active session from the response.")
            elseif err == "connection_failed" then
              text = _("Goodreads: connection failed")
            else
              text = _("Goodreads: ") .. tostring(err or _("connection failed"))
            end
          end
          UIManager:show(InfoMessage:new { text = text, icon = icon })
        end

        local function run_test(_wifi_enabled, wifi_error)
          if wifi_error then
            UIManager:close(loading)
            show_result({ ok = false, error = "no_network" })
            return
          end

          local result = self.api:testConnection()
          UIManager:close(loading)
          show_result(result)
        end

        if self.provider and self.provider.wifi then
          self.provider.wifi:withWifi(run_test)
        else
          run_test()
        end
      end,
    },
    {
      text = _("Cookie Auto-Refresh URL"),
      keep_menu_open = true,
      text_func = function()
        local set = self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL)
        return _("Cookie Auto-Refresh URL") .. (set and set ~= "" and _(" (set)") or _(" (optional)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Optional. A configured refresher can provide the first cookie when the Goodreads Cookie above is blank, and can replace a cookie Goodreads rejects.

Run the small local helper (see the separate goodreads-cookie-refresher repo) to keep a real logged-in browser alive on your home network and hand out fresh cookies automatically. Point this at its base address, e.g. http://192.168.1.50:5080 -- no path needed, just leave blank to disable.]]),
        })
      end,
      callback = function()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new {
          title = _("Cookie Auto-Refresh URL"),
          input = self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL) or "",
          input_hint = "http://192.168.1.50:5080",
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
                  self.settings:updateSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL, dialog:getInputText())
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
      text = _("Cookie Auto-Refresh Token"),
      keep_menu_open = true,
      text_func = function()
        local set = self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_TOKEN)
        return _("Cookie Auto-Refresh Token") .. (set and set ~= "" and _(" (set)") or _(" (optional)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("Only needed if the refresher's REFRESHER_AUTH_TOKEN is set in its .env -- must match exactly. Leave blank if you didn't set one there."),
        })
      end,
      callback = function()
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new {
          title = _("Cookie Auto-Refresh Token"),
          input = self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_TOKEN) or "",
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
                  self.settings:updateSetting(SETTING.GOODREADS.COOKIE_REFRESH_TOKEN, dialog:getInputText())
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
