local _ = require("gettext")
local math = require("math")

local T = require("ffi/util").template

local Event = require("ui/event")
local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")

local _t = require("shelfsync/lib/common/table_util")

local GOODREADS = require("shelfsync/lib/goodreads/constants")
local ICON = require("shelfsync/lib/common/constants/icons")
local SETTING = require("shelfsync/lib/common/constants/settings")

-- Falls back to shelfsync_config.lua's legacy cookie, same as api.lua's
-- get_headers(), so the menu doesn't show "(not set)" for a cookie that's
-- actually in use (e.g. carried over from a pre-Settings-menu install).
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local legacy_config = (config_ok and shelfsync_config.goodreads) or {}

local GoodreadsMenu = {}
GoodreadsMenu.__index = GoodreadsMenu

function GoodreadsMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

function GoodreadsMenu:isActive()
  return self.settings:providerEnabled()
    and self.api:hasCredential()
    and (self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true)
end

function GoodreadsMenu:mainMenu()
  return {
    enabled_func = function()
      return true
    end,
    text_func = function()
      return self.settings:bookLinked() and _("Goodreads: " .. ICON.LINK) or _("Goodreads")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

function GoodreadsMenu:getSubMenuItems(book_view)
  local menu_items = {
    {
      text = _("Enabled"),
      checked_func = function()
        return self.settings:providerEnabled()
      end,
      callback = function()
        self.settings:setProviderEnabled(not self.settings:providerEnabled())
      end,
      separator = true,
    },
    book_view and {
      text_func = function()
        if self.settings:bookLinked() then
          local title = self.settings:getLinkedTitle()
          if not title then
            title = self.settings:getLinkedBookId()
          end
          return _("Linked book: " .. title)
        else
          return _("Link book")
        end
      end,
      enabled_func = function()
        return self:isActive()
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          self.settings:updateBookSetting(
            self.ui.document.file,
            {
              _delete = { 'book_id', 'edition_id', 'pages', 'title' }
            }
          )

          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        if not self:isActive() then
          return
        end

        local force_search = self.settings:bookLinked()

        self.goodreads:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
      separator = true
    },
    book_view and {
      text = _("Automatically track progress"),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        local sync = not self.settings:syncEnabled()
        self.settings:setSync(sync)
      end,
    },
    book_view and {
      text = _("Update status"),
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        self.cache:cacheUserBook()

        return self:getStatusSubMenuItems()
      end,
      separator = true
    },
    book_view and {
      text = _("Jump to linked book position"),
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        UIManager:broadcastEvent(Event:new("GoodreadsPullPosition"))
      end,
      separator = true
    },
    {
      text = _("Account (Cookie)"),
      sub_item_table_func = function()
        return self:getAuthSubMenuItems()
      end,
    },
  }
  return _t.filter(menu_items, function(v)
    return v
  end)
end

-- Builds a radio menu item that marks the current book with `status_id` on
-- Goodreads (after confirmation), used for every entry in the status list
-- below. Unlike StoryGraph/Hardcover, there's no "Remove" entry here --
-- available HAR captures never covered a legacy unshelve action, so it's
-- left out rather than guessed at; users can remove a shelf from the
-- Goodreads website directly.
function GoodreadsMenu:_statusMenuItem(icon, status_id)
  return {
    text = _(icon .. " " .. GOODREADS.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(GOODREADS.STATUS_NAME[status_id]),
        ok_callback = function()
          self.cache:updateBookStatus(self.ui.document.file, status_id)
          menu_instance.item_table = self:getStatusSubMenuItems()
          menu_instance:updateItems()
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
  }
end

function GoodreadsMenu:getStatusSubMenuItems()
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, GOODREADS.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, GOODREADS.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, GOODREADS.STATUS.FINISHED),
    self:_statusMenuItem(ICON.PAUSE, GOODREADS.STATUS.PAUSED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, GOODREADS.STATUS.DNF),
  }

  local status = self.state.book_status.status_id

  -- Update progress: only when NOT read, DNF, removed, or want to read
  if status and status ~= GOODREADS.STATUS.FINISHED and status ~= GOODREADS.STATUS.DNF and status ~= GOODREADS.STATUS.TO_READ then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.goodreads:getRemotePercent(self.state.book_status) or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

  return items
end

function GoodreadsMenu:getAuthSubMenuItems()
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
      text = _("Cookie Auto-Refresh URL"),
      keep_menu_open = true,
      text_func = function()
        local set = self.settings:readSetting(SETTING.GOODREADS.COOKIE_REFRESH_URL)
        return _("Cookie Auto-Refresh URL") .. (set and set ~= "" and _(" (set)") or _(" (optional)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Optional. If the Goodreads Cookie above goes stale, syncing normally just fails until you repaste a fresh one by hand.

Instead, you can run a small local helper (see the separate goodreads-cookie-refresher repo) that keeps a real logged-in browser alive on your home network and hands out fresh cookies automatically. Point this at its base address, e.g. http://192.168.1.50:5080 -- no path needed, just leave blank to disable.]]),
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

return GoodreadsMenu
