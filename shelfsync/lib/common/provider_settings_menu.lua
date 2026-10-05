local _ = require("gettext")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local SETTING = require("shelfsync/lib/common/constants/settings")

local ProviderSettingsMenu = {}
ProviderSettingsMenu.__index = ProviderSettingsMenu

function ProviderSettingsMenu:new(o)
  return setmetatable(o or {}, self)
end

local function linkItem(manual_link_dialog)
  return {
    text = _("Link or relink book"),
    callback = function(menu_instance)
      manual_link_dialog:show(nil, function()
        menu_instance:updateItems()
      end)
    end,
    keep_menu_open = true,
  }
end

local function trackingItem(provider, engine)
  local item = {
    text = _("Automatically track progress"),
    checked_func = function()
      return engine.settings:syncEnabled()
    end,
    callback = function()
      engine.settings:setSync(not engine.settings:syncEnabled())
    end,
  }

  if provider.key == "hardcover" then
    item.enabled_func = function()
      return engine.settings:bookLinked()
    end
  elseif provider.key == "pagebound" then
    item.text_func = function()
      local reason
      if not engine.settings:providerEnabled() then
        reason = _("enable Pagebound first")
      elseif not engine.api:hasCredential() then
        reason = _("log in first")
      elseif not engine.enabled and engine.plugin_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) ~= true then
        reason = _("update ShelfSync to continue")
      elseif not engine.settings:bookLinked() then
        reason = _("link this book first")
      end
      if reason then
        return T(_("Automatically track progress (%1)"), reason)
      end
      return _("Automatically track progress")
    end
    item.enabled_func = function()
      return engine:isActive() and engine.settings:bookLinked()
    end
  else
    item.enabled_func = function()
      return engine:isActive() and engine.settings:bookLinked()
    end
  end

  local original_text = item.text
  local original_text_func = item.text_func
  item.text = nil
  item.text_func = function()
    local label = original_text_func and original_text_func() or original_text
    return _(provider.label .. ": " .. label)
  end
  return item
end

local function pullPositionItem(provider, engine)
  return {
    text = _(provider.label),
    enabled_func = function()
      return engine:isActive() and engine.settings:bookLinked()
    end,
    callback = function()
      UIManager:broadcastEvent(Event:new(provider.prefix .. "PullPosition"))
    end,
  }
end

local function storygraphOptions(engine, has_document)
  if not has_document then
    return {}
  end
  return {
    {
      text_func = function()
        local format = engine.settings:getLinkedEditionFormat()
        if format then
          return _("Change edition: " .. format)
        elseif engine.settings:getLinkedEditionId() then
          return _("Change edition: physical book")
        end
        return _("Change edition")
      end,
      enabled_func = function()
        return engine:isActive() and engine.settings:bookLinked()
      end,
      callback = function(menu_instance)
        engine.provider:showChangeEditionDialog(function()
          menu_instance:updateItems()
        end)
      end,
      keep_menu_open = true,
    },
  }
end

local function hardcoverOptions(engine, has_document)
  local items = {}
  if has_document then
    table.insert(items, {
      text_func = function()
        local format = engine.settings:getLinkedEditionFormat()
        if format then
          return _("Change edition: " .. format)
        elseif engine.settings:getLinkedEditionId() then
          return _("Change edition: physical book")
        end
        return _("Change edition")
      end,
      enabled_func = function()
        return engine:isActive() and engine.settings:bookLinked()
      end,
      callback = function(menu_instance)
        local editions = engine.api:findEditions(engine.settings:getLinkedBookId(), engine.user:getId())
        engine.dialog_manager:buildSearchDialog(
          "Select edition",
          editions,
          { edition_id = engine.settings:getLinkedEditionId() },
          function(book)
            engine.provider:linkBookManually(book)
            menu_instance:updateItems()
          end
        )
      end,
    })
  end

  table.insert(items, {
    text = _("Suggest a book"),
    enabled_func = function()
      return engine:isActive()
    end,
    callback = function()
      engine.provider:showRandomBookDialog()
    end,
    separator = true,
    keep_menu_open = true,
  })
  return items
end

function ProviderSettingsMenu:getSubMenuItems()
  local has_document = self.ui.document ~= nil
  local enable_items = {}
  local tracking_items = {}
  local pull_position_items = {}
  local option_items = {}

  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    local engine = self.engines[current_provider.key]
    table.insert(enable_items, {
      text = _(current_provider.label),
      checked_func = function()
        return engine.settings:providerEnabled()
      end,
      callback = function()
        engine.settings:setProviderEnabled(not engine.settings:providerEnabled())
      end,
    })

    if has_document then
      table.insert(tracking_items, trackingItem(current_provider, engine))
      table.insert(pull_position_items, pullPositionItem(current_provider, engine))
    end

    local provider_options
    if current_provider.key == "storygraph" then
      provider_options = storygraphOptions(engine, has_document)
    elseif current_provider.key == "hardcover" then
      provider_options = hardcoverOptions(engine, has_document)
    end

    if provider_options and #provider_options > 0 then
      table.insert(option_items, {
        text = _(current_provider.label .. " options"),
        sub_item_table = provider_options,
      })
    end
  end

  local menu_items = {
    {
      text = _("Enable or disable providers"),
      sub_item_table = enable_items,
    },
  }

  if has_document then
    table.insert(menu_items, linkItem(self.manual_link_dialog))
    table.insert(menu_items, {
      text = _("Automatically track progress"),
      sub_item_table = tracking_items,
    })
    table.insert(menu_items, {
      text = _("Jump to linked book position"),
      sub_item_table = pull_position_items,
    })
    table.insert(menu_items, self.update_status_menu:menuItem())
  end

  for _option_index, item in ipairs(option_items) do
    table.insert(menu_items, item)
  end

  return menu_items
end

function ProviderSettingsMenu:mainMenu()
  return {
    text = _("Provider settings"),
    sub_item_table_func = function()
      return self:getSubMenuItems()
    end,
  }
end

return ProviderSettingsMenu
