local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local InfoMessage = require("ui/widget/infomessage")
local SETTING = require("shelfsync/lib/common/constants/settings")

local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local legacy_config_storygraph = (config_ok and shelfsync_config.storygraph) or {}
local legacy_config_hardcover = (config_ok and shelfsync_config.hardcover) or {}
local legacy_config_goodreads = (config_ok and shelfsync_config.goodreads) or {}

local function storygraphAccountItems(self)
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
        if not set or set == "" then set = legacy_config_storygraph.session_cookie end
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
              text = self.settings:readSetting(SETTING.STORYGRAPH.SESSION_COOKIE) or legacy_config_storygraph.session_cookie or "",
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
        if not set or set == "" then set = legacy_config_storygraph.remember_user_token end
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
              text = self.settings:readSetting(SETTING.STORYGRAPH.REMEMBER_TOKEN) or legacy_config_storygraph.remember_user_token or "",
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


local function hardcoverAccountItems(self)
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
        if not set or set == "" then set = legacy_config_hardcover.token end
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
              text = self.settings:readSetting(SETTING.HARDCOVER.API_TOKEN) or legacy_config_hardcover.token or "",
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


local function goodreadsAccountItems(self)
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
        if not set or set == "" then set = legacy_config_goodreads.cookie end
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
              text = self.settings:readSetting(SETTING.GOODREADS.SESSION_COOKIE) or legacy_config_goodreads.cookie or "",
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

        if self.wifi then
          self.wifi:withWifi(run_test)
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

Run the small local helper (see the separate goodreads-cookie-refresher repo) to keep a real logged-in browser alive on your home network and hand out fresh cookies automatically. Point this at its base address, e.g. http://192.168.1.50:5080. For a named account in a multi-account refresher, include its path, e.g. http://192.168.1.50:5080/accounts/girlfriend. Leave blank to disable.]]),
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


local function fableAccountItems(self)
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


local function pageboundAccountItems(self)
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

local AccountsMenu = {}
AccountsMenu.__index = AccountsMenu

function AccountsMenu:new(o)
  return setmetatable(o or {}, self)
end

local account_items = {
  storygraph = storygraphAccountItems,
  hardcover = hardcoverAccountItems,
  goodreads = goodreadsAccountItems,
  fable = fableAccountItems,
  pagebound = pageboundAccountItems,
}

function AccountsMenu:getSubMenuItems()
  local menu_items = {}
  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    local engine = self.engines[current_provider.key]
    local context = setmetatable({ [current_provider.key] = engine.provider }, { __index = engine })
    table.insert(menu_items, {
      text_func = function()
        local authenticated = engine.api:hasCredential()
        return _(current_provider.label) .. (authenticated and " ✓" or "")
      end,
      sub_item_table_func = function()
        return account_items[current_provider.key](context)
      end,
    })
  end
  return menu_items
end

function AccountsMenu:mainMenu()
  return {
    text = _("Accounts"),
    sub_item_table_func = function()
      return self:getSubMenuItems()
    end,
  }
end

return AccountsMenu
