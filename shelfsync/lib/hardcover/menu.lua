local DataStorage = require("datastorage")
local Device = require("device")
local _ = require("gettext")
local math = require("math")
local os = require("os")

local T = require("ffi/util").template

local Event = require("ui/event")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")

local UpdateDoubleSpinWidget = require("shelfsync/lib/common/ui/update_double_spin_widget")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")

local Github = require("shelfsync/lib/common/github")
local _t = require("shelfsync/lib/common/table_util")

local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local ICON = require("shelfsync/lib/common/constants/icons")
local SETTING = require("shelfsync/lib/common/constants/settings")
local VERSION = require("shelfsync_version")

local HardcoverMenu = {}
HardcoverMenu.__index = HardcoverMenu

function HardcoverMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

local privacy_labels = {
  [HARDCOVER.PRIVACY.PUBLIC] = "Public",
  [HARDCOVER.PRIVACY.FOLLOWS] = "Follows",
  [HARDCOVER.PRIVACY.PRIVATE] = "Private"
}

-- Plugin update checks/blocks are plugin-wide, not per-provider, so the
-- "ignore version block" override lives in the shared plugin settings
-- (self.plugin_settings, injected by main.lua) rather than Hardcover's own
-- settings file, which has no "Plugin Updates" section of its own.
function HardcoverMenu:isActive()
  return self.enabled or self.plugin_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
end

function HardcoverMenu:mainMenu()
  return {
    enabled_func = function()
      return true
    end,
    text_func = function()
      return self.settings:bookLinked() and _("Hardcover: " .. ICON.LINK) or _("Hardcover")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

function HardcoverMenu:getSubMenuItems(book_view)
  local menu_items = {
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
        -- leave button enabled to allow clearing local link when api disabled
        return self:isActive() or self.settings:bookLinked()
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          self.settings:updateBookSetting(
            self.ui.document.file,
            {
              _delete = { 'book_id', 'edition_id', 'edition_format', 'pages', 'title' }
            }
          )

          menu_instance.item_table = self:getSubMenuItems(book_view)
          menu_instance:updateItems()
        end
      end,
      callback = function(menu_instance)
        if not self:isActive() then
          return
        end

        local force_search = self.settings:bookLinked()

        self.hardcover:showLinkBookDialog(force_search, function()
          menu_instance.item_table = self:getSubMenuItems(book_view)
          menu_instance:updateItems()
        end)
      end,
    },
    book_view and {
      text_func = function()
        local edition_format = self.settings:getLinkedEditionFormat()
        local title = "Change edition"

        if edition_format then
          title = title .. ": " .. edition_format
        elseif self.settings:getLinkedEditionId() then
          return title .. ": physical book"
        end

        return _(title)
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function(menu_instance)
        local editions = self.api:findEditions(self.settings:getLinkedBookId(), self.user:getId())
        self.dialog_manager:buildSearchDialog(
          "Select edition",
          editions,
          {
            edition_id = self.settings:getLinkedEditionId()
          },
          function(book)
            self.hardcover:linkBook(book)
            menu_instance:updateItems()
          end
        )
      end,
    },
    book_view and {
      text = _("Automatically track progress"),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      callback = function()
        local sync = not self.settings:syncEnabled()
        self.settings:setSync(sync)
      end,
    },
    book_view and {
      text = _("Jump to Hardcover position"),
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        UIManager:broadcastEvent(Event:new("HardcoverPullPosition"))
      end,
      separator = true
    },
    book_view and {
      text = _("Update status"),
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        self.cache:cacheUserBook()

        return self:getStatusSubMenuItems()
      end,
      separator = true
    },
    {
      text = _("Suggest a book"),
      callback = function()
        self.hardcover:showRandomBookDialog()
      end,
      separator = true,
      keep_menu_open = true
    },
    {
      text = _("Settings"),
      sub_item_table_func = function()
        return self:getSettingsSubMenuItems()
      end,
    },
    {
      text = _("About"),
      callback = function()
        local info = Github:fetchVersionInfo()
        local version = table.concat(VERSION, ".")
        local new_release_str = ""
        if info and info.plugin_version and Github:isNewer(info.plugin_version) then
          new_release_str = " (latest v" .. info.plugin_version .. ")"
        end
        local settings_file = DataStorage:getSettingsDir() .. "/" .. "hardcoversync_settings.lua"

        UIManager:show(InfoMessage:new {
          text = [[
Hardcover plugin
v]] .. version .. new_release_str .. [[


Updates book progress and status on hardcover.app

Project:
github.com/Lyfts/ShelfSync

Settings:
]] .. settings_file,
          face = Font:getFace("cfont", 18),
          show_icon = false,
        })
      end,
      keep_menu_open = true
    }
  }
  return _t.filter(menu_items, function(v)
    return v
  end)
end

-- Builds a radio menu item that marks the current book with `status_id` on
-- Hardcover (after confirmation), used for every entry in the status list
-- below except "Remove", which has no status_id of its own to set.
function HardcoverMenu:_statusMenuItem(icon, status_id)
  return {
    text = _(icon .. " " .. HARDCOVER.STATUS_NAME[status_id]),
    enabled_func = function()
      return self:isActive()
    end,
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(HARDCOVER.STATUS_NAME[status_id]),
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

function HardcoverMenu:getVisibilitySubMenuItems()
  return {
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PUBLIC]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PUBLIC
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.PUBLIC)
      end,
      radio = true,
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.FOLLOWS]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.FOLLOWS
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.FOLLOWS)
      end,
      radio = true
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PRIVATE]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PRIVATE
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.PRIVATE)
      end,
      radio = true
    },
  }
end

function HardcoverMenu:getStatusSubMenuItems()
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, HARDCOVER.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, HARDCOVER.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, HARDCOVER.STATUS.FINISHED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, HARDCOVER.STATUS.DNF),
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = self.api:removeRead(self.state.book_status.id)
            if result then
              self.state.book_status = {}
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text_func = function()
        local reads = self.state.book_status.user_book_reads
        local current_page = reads and reads[#reads] and reads[#reads].progress_pages or 0
        local max_pages = self.settings:pages()

        if not max_pages then
          max_pages = "???"
        end

        return T(_("Update page: %1 of %2"), current_page, max_pages)
      end,
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id == HARDCOVER.STATUS.READING and self.settings:pages()
      end,
      callback = function(menu_instance)
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local last_hardcover_page = current_read and current_read.progress_pages or 0

        local document_page = self.ui:getCurrentPage()
        local document_pages = self.ui.document:getPageCount()

        local remote_pages = self.settings:pages()
        local mapped_page = self.page_mapper:getMappedPage(document_page, document_pages, remote_pages)

        local left_text = "Edition"
        if last_hardcover_page > 0 then
          left_text = left_text .. ": was " .. last_hardcover_page
        end

        local spinner = UpdateDoubleSpinWidget:new {
          ok_always_enabled = true,

          left_text = left_text,
          left_value = mapped_page,
          left_min = 0,
          left_max = remote_pages,
          left_step = 1,
          left_hold_step = 20,

          right_text = "Local page",
          right_value = document_page,
          right_min = 0,
          right_max = document_pages,
          right_step = 1,
          right_hold_step = 20,

          update_callback = function(new_edition_page, new_document_page, edition_page_changed)
            if edition_page_changed then
              local new_mapped_page = self.page_mapper:getUnmappedPage(new_edition_page, document_pages, remote_pages)
              return new_edition_page, new_mapped_page
            else
              local new_mapped_page = self.page_mapper:getMappedPage(new_document_page, document_pages, remote_pages)
              return new_mapped_page, new_document_page
            end
          end,
          ok_text = _("Set page"),
          title_text = _("Set current page"),

          callback = function(edition_page, _document_page)
            local result

            if current_read then
              result = self.api:updatePage(current_read.id, current_read.edition_id, edition_page,
                current_read.started_at)
            else
              local start_date = os.date("%Y-%m-%d")
              result = self.api:createRead(self.state.book_status.id, self.state.book_status.edition_id, edition_page,
                start_date)
            end

            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError("Page could not be saved")
            end
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = _("Add a note"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      callback = function()
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local current_page = current_read and current_read.progress_pages or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          nil,
          "note"
        )
      end,
      keep_menu_open = true
    },
    {
      text_func = function()
        local text
        if self.state.book_status.rating then
          text = "Update rating"
          local whole_star = math.floor(self.state.book_status.rating)
          local star_string = string.rep(ICON.STAR, whole_star)
          if self.state.book_status.rating - whole_star > 0 then
            star_string = star_string .. ICON.HALF_STAR
          end
          text = text .. ": " .. star_string
        else
          text = "Set rating"
        end

        return _(text)
      end,
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      callback = function(menu_instance)
        local rating = self.state.book_status.rating

        local spinner = SpinWidget:new {
          ok_always_enabled = rating == nil,
          value = rating or 2.5,
          value_min = 0,
          value_max = 5,
          value_step = 0.5,
          value_hold_step = 2,
          precision = "%.1f",
          ok_text = _("Save"),
          title_text = _("Set Rating"),
          callback = function(spin)
            local result = self.api:updateRating(self.state.book_status.id, spin.value)
            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError("Rating could not be saved")
            end
          end
        }
        UIManager:show(spinner)
      end,
      hold_callback = function(menu_instance)
        local result = self.api:updateRating(self.state.book_status.id, 0)
        if result then
          self.state.book_status = result
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true
    },
    {
      text = _("Set status visibility"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      sub_item_table_func = function()
        return self:getVisibilitySubMenuItems()
      end,
    },
  }

  return items
end

function HardcoverMenu:getTrackingSubMenuItems()
  return {
    {
      text = _("Auto sync by edition pages"),
      checked_func = function()
        return self.settings:syncByRemotePages()
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        local setting = self.settings:syncByRemotePages()
        self.settings:updateSetting(SETTING.SYNC_BY_REMOTE_PAGES, not setting)
      end,
    },
    {
      text = "Always track progress by default",
      checked_func = function()
        return self.settings:readSetting(SETTING.ALWAYS_SYNC) ~= false
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ALWAYS_SYNC) ~= false
        self.settings:updateSetting(SETTING.ALWAYS_SYNC, not setting)
      end,
    },
    {
      text = "Sync immediately when opening a book",
      checked_func = function()
        return self.settings:syncOnOpen()
      end,
      callback = function()
        local setting = self.settings:syncOnOpen()
        self.settings:updateSetting(SETTING.SYNC_ON_OPEN, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Try syncing progress as soon as a book is opened, rather than waiting for the first page turn or tracking interval.

Disable this if you'd rather sync only follow the usual periodic/threshold pattern below.]],
        })
      end,
      separator = true
    },
    {
      text = "Update periodically",
      radio = true,
      checked_func = function()
        return self.settings:trackByTime()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.FREQUENCY)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackFrequency() .. " minutes"
      end,
      enabled_func = function()
        return self.settings:trackByTime()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackFrequency(),
          value_min = 1,
          value_max = 120,
          value_step = 1,
          value_hold_step = 6,
          ok_text = _("Save"),
          title_text = _("Set track frequency"),
          callback = function(spin)
            self.settings:updateSetting(SETTING.TRACK_FREQUENCY, spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = "Update by progress",
      radio = true,
      checked_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.PROGRESS)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackPercentageInterval() .. " percent completed"
      end,
      enabled_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackPercentageInterval(),
          value_min = 1,
          value_max = 50,
          value_step = 1,
          value_hold_step = 10,
          ok_text = _("Save"),
          title_text = _("Set track progress"),
          callback = function(spin)
            self.settings:changeTrackPercentageInterval(spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = "Update by edition pages",
      radio = true,
      checked_func = function()
        return self.settings:trackMethod() == SETTING.TRACK.PAGES
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.PAGES)
      end
    },
    {
      text_func = function()
        if self.settings:trackMethod() == SETTING.TRACK.PAGES and not self.settings:trackByPages() then
          return _("No page count from Hardcover for this book — falling back to progress %")
        end
        return "Every " .. self.settings:trackPageStep() .. " pages completed"
      end,
      enabled_func = function()
        return self.settings:trackByPages()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackPageStep(),
          value_min = 1,
          value_max = 500,
          value_step = 1,
          value_hold_step = 10,
          ok_text = _("Save"),
          title_text = _("Set track pages"),
          callback = function(spin)
            self.settings:updateSetting(SETTING.TRACK_PAGE_STEP, spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
  }
end

function HardcoverMenu:getAuthSubMenuItems()
  return {
    {
      text = _("How to get your API token"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Hardcover uses an API token for authentication.

1. Log in to hardcover.app in a browser
2. Go to hardcover.app/account/api
3. Copy your API token into "Hardcover API Token" below

The token does not expire automatically, but can be regenerated (which invalidates the old one) from the same page.]]),
        })
      end,
      separator = true,
    },
    {
      text = _("Hardcover API Token"),
      text_func = function()
        local set = self.settings:readSetting(SETTING.API_TOKEN)
        return _("Hardcover API Token") .. (set and set ~= "" and _(" (set)") or _(" (not set)"))
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("Value of your Hardcover API token. See \"How to get your API token\" above."),
        })
      end,
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("Hardcover API Token"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.API_TOKEN) or "",
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
                  self.settings:updateSetting(SETTING.API_TOKEN, value)
                  UIManager:close(dialog)
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

function HardcoverMenu:getSettingsSubMenuItems()
  return {
    {
      text = "Automatically link by ISBN",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
        self.settings:updateSetting(SETTING.LINK_BY_ISBN, not setting)
      end
    },
    {
      text = "Automatically link by Hardcover identifiers",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) == true
        self.settings:updateSetting(SETTING.LINK_BY_HARDCOVER, not setting)
      end
    },
    {
      text = "Automatically link by title and author",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
        self.settings:updateSetting(SETTING.LINK_BY_TITLE, not setting)
      end,
      separator = true
    },
    {
      text = "Progress tracking settings",
      sub_item_table_func = function()
        return self:getTrackingSubMenuItems()
      end,
    },
    {
      text = "Enable wifi on demand",
      checked_func = function()
        return self.settings:readSetting(SETTING.ENABLE_WIFI) == true
      end,
      enabled_func = function()
        return Device:hasWifiRestore()
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ENABLE_WIFI) == true
        self.settings:updateSetting(SETTING.ENABLE_WIFI, not setting)
      end
    },
    {
      text = "Confirm changes to book read status",
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        local setting = self.settings:menuConfirm() == true
        self.settings:setMenuConfirm(not setting)
      end
    },
    {
      text = "Compatibility mode",
      checked_func = function()
        return self.settings:compatibilityMode()
      end,
      callback = function()
        local setting = self.settings:compatibilityMode()
        self.settings:updateSetting(SETTING.COMPATIBILITY_MODE, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Disable fancy menu for book and edition search results.

May improve compatibility for some versions of KOReader]],
        })
      end
    },
    {
      text = "Include location info in regular notes",
      checked_func = function()
        return self.settings:readSetting(SETTING.INCLUDE_LOCATION_IN_NOTES) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.INCLUDE_LOCATION_IN_NOTES) == true
        self.settings:updateSetting(SETTING.INCLUDE_LOCATION_IN_NOTES, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Automatically append Chapter, Page, and % info to your regular notes.

Quotes always include this info.]],
        })
      end,
    },
    {
      text = "Verbose logging",
      checked_func = function()
        return self.settings:verboseLogging()
      end,
      callback = function()
        local setting = self.settings:verboseLogging()
        self.settings:updateSetting(SETTING.VERBOSE_LOGGING, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Log extra detail useful for diagnosing sync issues to KOReader's log file.

Off by default since it can be noisy; only worth enabling while troubleshooting.]],
        })
      end,
      separator = true
    },
    {
      text = "Account (API Token)",
      sub_item_table_func = function()
        return self:getAuthSubMenuItems()
      end,
    },
  }
end

return HardcoverMenu
