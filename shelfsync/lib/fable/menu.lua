local _ = require("gettext")
local math = require("math")

local T = require("ffi/util").template

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local InfoMessage = require("ui/widget/infomessage")

local _t = require("shelfsync/lib/common/table_util")

local FABLE = require("shelfsync/lib/fable/constants")
local ICON = require("shelfsync/lib/common/constants/icons")
local SETTING = require("shelfsync/lib/common/constants/settings")

local FableMenu = {}
FableMenu.__index = FableMenu

function FableMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

function FableMenu:isActive()
  return self.settings:providerEnabled()
    and self.api:hasCredential()
    and (self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true)
end

function FableMenu:mainMenu()
  return {
    enabled_func = function()
      return true
    end,
    text_func = function()
      return self.settings:bookLinked() and _("Fable: " .. ICON.LINK) or _("Fable")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

function FableMenu:getSubMenuItems(book_view)
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
              _delete = { 'book_id', 'pages', 'title' }
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

        self.fable:showLinkBookDialog(force_search, function()
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
        UIManager:broadcastEvent(Event:new("FablePullPosition"))
      end,
      separator = true
    },
    {
      text = _("Account"),
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
-- Fable (after confirmation). Only 4 entries -- unlike Goodreads/Hardcover,
-- there's no Paused entry, since Fable has no "paused" system list to shelve
-- it on (confirmed via HAR, see fable/constants.lua's SYSTEM_TYPE).
function FableMenu:_statusMenuItem(icon, status_id)
  return {
    text = _(icon .. " " .. FABLE.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(FABLE.STATUS_NAME[status_id]),
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

function FableMenu:getStatusSubMenuItems()
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, FABLE.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, FABLE.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, FABLE.STATUS.FINISHED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, FABLE.STATUS.DNF),
  }

  local status = self.state.book_status.status_id

  -- Update progress: only when NOT read, DNF, or want to read
  if status and status ~= FABLE.STATUS.FINISHED and status ~= FABLE.STATUS.DNF and status ~= FABLE.STATUS.TO_READ then
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
        local remote_percent = self.fable:getRemotePercent(self.state.book_status) or 0

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

function FableMenu:getAuthSubMenuItems()
  return {
    {
      text = _("How Fable login works"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Unlike StoryGraph/Goodreads, Fable has a real login API, so this plugin logs in directly with your Fable email and password below.

Your password itself is never stored -- only the access/refresh token pair Fable's own login returns, the same thing its official app keeps, and that pair refreshes itself automatically from then on. If it's ever revoked (e.g. after changing your password), just log in again here.]]),
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
      callback = function()
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
      callback = function()
        self.dialog_manager:maybeConfirm({
          text = _("Log out of Fable on this device?"),
          ok_callback = function()
            self.settings:updateSetting(SETTING.FABLE.EMAIL, "")
            self.settings:updateSetting(SETTING.FABLE.ID_TOKEN, "")
            self.settings:updateSetting(SETTING.FABLE.REFRESH_TOKEN, "")
            self.settings:updateSetting(SETTING.FABLE.TOKEN_EXPIRES_AT, 0)
          end,
        })
      end,
    },
  }
end

return FableMenu
