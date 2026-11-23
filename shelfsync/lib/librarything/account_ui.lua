local _ = require("gettext")

local T = require("ffi/util").template

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local InfoMessage = require("ui/widget/infomessage")

local LIBRARYTHING = require("shelfsync/lib/librarything/constants")

local Account = {}

-- Runs `fn` once there's a network connection, with Wi-Fi turned on first
-- if "Enable wifi on demand" is set, and inside Trapper for the requests.
local function withNetwork(self, fn)
  local wifi = self.provider and self.provider.wifi
  if wifi then
    wifi:withWifi(function(_wifi_enabled, wifi_error)
      fn(wifi_error)
    end)
  else
    Trapper:wrap(function() fn() end)
  end
end

-- The book sources "Link book" can search for a book that isn't a
-- LibraryThing work yet, or none.
function Account.getAddSourceItems(self)
  local items = {}
  for _, source in ipairs(LIBRARYTHING.ADD_SOURCES) do
    table.insert(items, {
      text = source.name,
      radio = true,
      checked_func = function()
        local chosen = self.api:addSource()
        return chosen ~= nil and chosen.id == source.id
      end,
      callback = function()
        self.api:setAddSource(source)
      end,
    })
  end
  items[#items].separator = true
  table.insert(items, {
    text = _("Don't search other sources"),
    radio = true,
    checked_func = function()
      return self.api:addSource() == nil
    end,
    callback = function()
      self.api:setAddSource(false)
    end,
  })
  return items
end

-- The account's collections a read book can go to: any but Currently
-- reading and To read, which are statuses of their own.
function Account.getReadCollectionItems(self)
  local reading = self.api:collectionId(LIBRARYTHING.COLLECTION.READING)
  local to_read = self.api:collectionId(LIBRARYTHING.COLLECTION.TO_READ)
  local items = {}
  for _, collection in ipairs(self.api:collections()) do
    if collection.id ~= reading and collection.id ~= to_read then
      table.insert(items, {
        text = collection.name,
        radio = true,
        checked_func = function()
          return self.api:readCollection().id == collection.id
        end,
        callback = function()
          self.api:setReadCollection(collection)
        end,
      })
    end
  end
  if #items > 0 then
    items[#items].separator = true
  end

  table.insert(items, {
    text = _("Refresh the list from LibraryThing"),
    help_text = _("Gets your collections from LibraryThing again, e.g. after adding one there."),
    keep_menu_open = true,
    enabled_func = function()
      return self.api:hasCredential()
    end,
    callback = function(menu_instance)
      -- Only refreshed if it's still showing once the list's back.
      local item_table = menu_instance.item_table
      local info = InfoMessage:new { text = _("Getting your LibraryThing collections...") }
      UIManager:show(info)
      withNetwork(self, function(wifi_error)
        local collections, err
        if wifi_error then
          err = wifi_error
        else
          collections, err = self.api:refreshCollections()
        end
        UIManager:close(info)
        if not collections then
          UIManager:show(InfoMessage:new {
            text = _("LibraryThing: ") .. tostring(err or _("couldn't get your collections")),
            icon = "notice-warning",
          })
        elseif menu_instance.item_table == item_table then
          menu_instance.item_table = Account.getReadCollectionItems(self)
          menu_instance:updateItems()
        end
      end)
    end,
  })
  return items
end

function Account.items(self)
  return {
    {
      text = _("Sign in with LibraryThing"),
      help_text = _("Sign in with your LibraryThing username and password. ShelfSync caches your password to sign in again if the session expires, encrypted at rest when possible. The unofficial endpoint may change, and the password is sent in an HTTPS URL."),
      keep_menu_open = true,
      callback = function(menu_instance)
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("LibraryThing Sign In"),
          fields = {
            { text = self.api:username() or "", hint = _("Username") },
            { text = "", hint = _("Password"), text_type = "password" },
          },
          buttons = {
            {
              {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
              },
              {
                text = _("Sign in"),
                callback = function()
                  local fields = dialog:getFields()
                  local username, password = fields[1], fields[2]
                  UIManager:close(dialog)

                  Trapper:wrap(function()
                    local info = InfoMessage:new { text = _("Signing in to LibraryThing...") }
                    UIManager:show(info)
                    local ok, err = self.api:login(username, password)
                    UIManager:close(info)
                    if ok then
                      menu_instance:updateItems()
                      UIManager:show(InfoMessage:new { text = _("Signed in to LibraryThing") })
                    else
                      UIManager:show(InfoMessage:new {
                        text = _("LibraryThing sign-in failed: ") .. tostring(err or _("unknown error")),
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
      separator = true,
    },
    {
      text = _("How to sign in"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Sign in with your LibraryThing username and password, or use the session cookies from a browser signed in to librarything.com. ShelfSync caches your password to sign in again if the session expires, encrypted at rest when possible. Sign-in sends it in an HTTPS URL. Log out clears the cached password.

Only three cookies are needed: cookie_userid, cookie_usernum and cookie_userchecksum. To copy them from a browser:
- run the fetch-cookies helper from ShelfSync's releases with "--service librarything", and copy the shelfsync_config.lua it writes into the plugin's folder, or
- open the browser's dev tools (F12) > Application/Storage > Cookies > www.librarything.com, and enter the three under "Session cookies" as cookie_userid=...; cookie_usernum=...; cookie_userchecksum=...

The sign-in endpoint is unofficial and may change.

librarything.com is protected by Cloudflare, which can ask a browser to prove it isn't a bot. ShelfSync can't do that, so if Cloudflare challenges it, syncing fails until Cloudflare lets it through again. "Test connection" shows whether that's happening.]]),
        })
      end,
      separator = true,
    },
    {
      text_func = function()
        local username = self.api:hasCredential() and self.api:username()
        return username and T(_("Session cookies (%1)"), username) or _("Session cookies (not set)")
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new {
          title = _("LibraryThing session cookies"),
          input = "",
          input_hint = "cookie_userid=...; cookie_usernum=...; cookie_userchecksum=...",
          description = _("Paste the cookie_userid, cookie_usernum and cookie_userchecksum cookies from a browser signed in to librarything.com. Any other cookies are ignored."),
          buttons = {
            {
              {
                text = _("Cancel"),
                id = "close",
                callback = function()
                  UIManager:close(dialog)
                end,
              },
              {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                  local saved = self.api:saveSessionCookie(dialog:getInputText())
                  UIManager:close(dialog)
                  if saved then
                    menu_instance:updateItems()
                    UIManager:show(InfoMessage:new { text = _("LibraryThing session saved") })
                  else
                    UIManager:show(InfoMessage:new {
                      text = _("Those aren't LibraryThing's session cookies. cookie_userid, cookie_usernum and cookie_userchecksum are all needed."),
                      icon = "notice-warning",
                    })
                  end
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
      text = _("Test connection"),
      keep_menu_open = true,
      enabled_func = function()
        return self.api:hasCredential()
      end,
      callback = function()
        local info = InfoMessage:new { text = _("Testing LibraryThing connection...") }
        UIManager:show(info)
        withNetwork(self, function(wifi_error)
          local ok, err
          if wifi_error then
            err = wifi_error
          else
            ok, err = self.api:testConnection()
          end
          UIManager:close(info)
          if ok then
            UIManager:show(InfoMessage:new {
              text = T(_("LibraryThing: connection OK (%1)"), tostring(self.api:username())),
            })
          else
            UIManager:show(InfoMessage:new {
              text = _("LibraryThing: ") .. tostring(err or _("connection failed")),
              icon = "notice-warning",
            })
          end
        end)
      end,
      separator = true,
    },
    {
      text = _("Log out"),
      enabled_func = function()
        return self.api:hasCredential()
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = _("Log out of LibraryThing on this device?"),
          ok_callback = function()
            self.api:logout()
            menu_instance:updateItems()
            -- The session in shelfsync_config.lua is used whenever none's saved.
            if self.api:hasCredential() then
              UIManager:show(InfoMessage:new {
                text = _("The LibraryThing session in shelfsync_config.lua is still used. Remove it from that file to log out."),
              })
            end
          end,
        })
      end,
    },
  }
end

return Account
