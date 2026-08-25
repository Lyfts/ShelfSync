-- Settings shared across every provider (progress tracking, wifi-on-demand,
-- confirmation prompts, compatibility mode, note location info, verbose
-- logging, and plugin update checks), surfaced once under the top-level
-- ShelfSync > Common settings menu instead of being configured separately
-- per service. `settings` is the shared plugin_settings instance (see
-- ShelfSyncApp:init/base_settings.lua's SHARED_KEYS), and `app` is the
-- ShelfSyncApp instance, needed to (re)start/cancel both engines' pending
-- updates when a version-block override changes.
local Device = require("device")
local _ = require("gettext")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")

local SETTING = require("shelfsync/lib/common/constants/settings")

local CommonMenu = {}
CommonMenu.__index = CommonMenu

function CommonMenu:new(o)
  return setmetatable(o or {}, self)
end

function CommonMenu:getTrackingSubMenuItems()
  return {
    {
      text = _("Auto sync by edition pages"),
      checked_func = function()
        return self.settings:syncByRemotePages()
      end,
      callback = function()
        local setting = self.settings:syncByRemotePages()
        self.settings:updateSetting(SETTING.SYNC_BY_REMOTE_PAGES, not setting)
      end,
    },
    {
      text = _("Always track progress by default"),
      checked_func = function()
        return self.settings:readSetting(SETTING.ALWAYS_SYNC) ~= false
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ALWAYS_SYNC) ~= false
        self.settings:updateSetting(SETTING.ALWAYS_SYNC, not setting)
      end,
    },
    {
      text = _("Sync immediately when opening a book"),
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
      text = _("Update periodically"),
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
      text = _("Update by progress"),
      radio = true,
      checked_func = function()
        return self.settings:trackMethod() == SETTING.TRACK.PROGRESS
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
      text = _("Update by edition pages"),
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
          return _("No page count for this book's linked edition — falling back to progress %")
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

function CommonMenu:getUpdateSubMenuItems()
  return {
    {
      text = _("Ignore version blocks"),
      checked_func = function()
        return self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
      end,
      callback = function(menu_instance)
        local setting = self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
        local new_setting = not setting
        self.settings:updateSetting(SETTING.IGNORE_VERSION_BLOCK, new_setting)

        if new_setting then
          UIManager:show(Notification:new {
            text = _("ShelfSync: Version block ignored. Sync enabled."),
            timeout = 5
          })
          self.app:startReadCache()
        else
          UIManager:show(Notification:new {
            text = _("ShelfSync: Version block active. Sync disabled."),
            timeout = 5
          })
          self.app:cancelPendingUpdates()
        end
        menu_instance:updateItems()
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Bypass mandatory update requirements. Use at your own risk as older versions may break sync or cause errors if the StoryGraph/Hardcover API changes.]],
        })
      end
    },
    {
      text = _("Show version alert dialog"),
      checked_func = function()
        return self.settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false
      end,
      callback = function(menu_instance)
        local setting = self.settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false
        self.settings:updateSetting(SETTING.SHOW_VERSION_DIALOG, not setting)
        menu_instance:updateItems()
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Show a popup dialog when a mandatory update is required. If disabled, the plugin will silently stop working until updated.]],
        })
      end
    },
    {
      text = _("Version check frequency"),
      callback = function(menu_instance)
        local current = self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
        if type(current) == "table" then current = 1 end
        local spinner
        spinner = SpinWidget:new {
          value = current,
          min = 1,
          max = 30,
          unit = " day(s)",
          title = "Check for updates every X days",
          callback = function(v1, v2)
            local value = type(v1) == "number" and v1 or v2
            self.settings:updateSetting(SETTING.VERSION_CHECK_INTERVAL, value)
            UIManager:close(spinner)
            menu_instance:updateItems()
          end,
        }
        UIManager:show(spinner)
      end,
      text_func = function()
        local current = self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
        if type(current) == "table" then current = 1 end
        return "Check frequency: " .. current .. " day(s)"
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[How often to check for mandatory updates. Default is 1 day.]],
        })
      end
    },
  }
end

function CommonMenu:getSubMenuItems()
  return {
    {
      text = _("Progress tracking settings"),
      sub_item_table_func = function()
        return self:getTrackingSubMenuItems()
      end,
    },
    {
      text = _("Enable wifi on demand"),
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
      text = _("Confirm changes to book read status"),
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        local setting = self.settings:menuConfirm() == true
        self.settings:setMenuConfirm(not setting)
      end
    },
    {
      text = _("Compatibility mode"),
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
      text = _("Include location info in regular notes"),
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
      text = _("Verbose logging"),
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
      text = _("Plugin Updates"),
      sub_item_table_func = function()
        return self:getUpdateSubMenuItems()
      end,
    },
  }
end

return CommonMenu
