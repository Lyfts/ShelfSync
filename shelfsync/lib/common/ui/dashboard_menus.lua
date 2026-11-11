local _ = require("gettext")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local PROVIDERS = require("shelfsync/lib/common/constants/providers")

local Menus = {}

function Menus.connections(app)
  local enabled, accounts = {}, {}
  for _index, provider in ipairs(PROVIDERS) do
    local engine = app.engines[provider.key]
    table.insert(enabled, {
      text = _(provider.label),
      checked_func = function() return engine.settings:providerEnabled() end,
      callback = function() engine.settings:setProviderEnabled(not engine.settings:providerEnabled()) end,
    })
    table.insert(accounts, {
      text_func = function()
        return _(provider.label) .. "  ·  " .. (engine.api:hasCredential() and _("Credentials saved") or _("Sign in"))
      end,
      sub_item_table_func = function() return provider.account_ui.items(engine) end,
    })
  end
  return {
    { text = _("Enabled services"), sub_item_table = enabled },
    { text = _("Accounts and sign in"), sub_item_table = accounts },
  }
end

function Menus.tracking(app)
  local items = {
    {
      text = _("Enable tracking for all linked services"),
      callback = function()
        for _index, provider in ipairs(PROVIDERS) do
          local engine = app.engines[provider.key]
          if engine:isActive() and engine.settings:bookLinked() then engine.settings:setSync(true) end
        end
      end,
    },
    {
      text = _("Disable tracking for all linked services"),
      callback = function()
        for _index, provider in ipairs(PROVIDERS) do
          local engine = app.engines[provider.key]
          if engine:isActive() and engine.settings:bookLinked() then engine.settings:setSync(false) end
        end
      end,
    },
  }
  for _index, provider in ipairs(PROVIDERS) do
    local engine = app.engines[provider.key]
    table.insert(items, {
      text = _(provider.label),
      enabled_func = function() return engine:isActive() and engine.settings:bookLinked() end,
      checked_func = function() return engine.settings:bookLinked() and engine.settings:syncEnabled() end,
      callback = function() engine.settings:setSync(not engine.settings:syncEnabled()) end,
    })
  end
  return items
end

function Menus.bookOptions(app)
  local exceptions, editions, positions = {}, {}, {}
  local selected = {}
  for _index, provider in ipairs(PROVIDERS) do
    local engine = app.engines[provider.key]
    local available = function() return engine:isActive() and engine.settings:bookLinked() end
    if provider.key ~= "librarything" then
      table.insert(exceptions, {
        text = _(provider.label),
        enabled_func = available,
        sub_item_table_func = function()
          engine.cache:cacheUserBook()
          local outliers = provider.book_actions.items(engine)
          if #outliers == 0 then
            table.insert(outliers, { text = _("No additional actions available"), enabled = false })
          end
          return outliers
        end,
      })
    end
    if provider.key ~= "librarything" then
      table.insert(positions, {
        text = _(provider.label), enabled_func = available,
        callback = function() UIManager:broadcastEvent(Event:new(provider.prefix .. "PullPosition")) end,
      })
    end
    if provider.key == "storygraph" or provider.key == "hardcover" then
      table.insert(editions, {
        text = _(provider.label), enabled_func = available,
        callback = function(menu)
          if provider.key == "storygraph" then
            engine.provider:showChangeEditionDialog(function() menu:updateItems() end)
          else
            local edition_results = engine.api:findEditions(engine.settings:getLinkedBookId(), engine.user:getId())
            engine.dialog_manager:buildSearchDialog(_("Select edition"), edition_results,
              { edition_id = engine.settings:getLinkedEditionId() }, function(book)
                engine.provider:linkBookManually(book)
                menu:updateItems()
              end)
          end
        end,
        keep_menu_open = true,
      })
    end
  end
  return {
    { text = _("Remove reading status from services"), sub_item_table_func = function()
      local items = {}
      for _index, provider in ipairs(PROVIDERS) do
        local engine = app.engines[provider.key]
        table.insert(items, {
          text = _(provider.label),
          enabled_func = function() return engine:isActive() and engine.settings:bookLinked() end,
          checked_func = function() return selected[provider.key] == true end,
          callback = function() selected[provider.key] = not selected[provider.key] end,
        })
      end
      table.insert(items, {
        text = _("Remove from selected services"),
        callback = function(menu)
          local document, targets, labels = app.ui.document, {}, {}
          local item_table = menu and menu.item_table
          if not document then return end
          for _index, provider in ipairs(PROVIDERS) do
            local engine = app.engines[provider.key]
            if selected[provider.key] and engine:isActive() and engine.settings:bookLinked() then
              table.insert(targets, {
                engine = engine,
                key = provider.key,
                book_id = engine.settings:readBookSetting(document.file, "book_id"),
              })
              table.insert(labels, engine.label)
            end
          end
          if #targets == 0 then
            UIManager:show(InfoMessage:new { text = _("Select at least one linked service.") })
            return
          end
          targets[1].engine.dialog_manager:maybeConfirm({
            text = _("Remove this book's reading status from ") .. table.concat(labels, ", ")
              .. _("? The local links will remain."),
            ok_callback = function()
              local succeeded, failed = {}, {}
              local function nextTarget(index)
                local target = targets[index]
                if not target then
                  local messages = {}
                  if #succeeded > 0 then
                    table.insert(messages, _("Removed from: ") .. table.concat(succeeded, ", "))
                  end
                  if #failed > 0 then
                    table.insert(messages, _("Could not remove from: ") .. table.concat(failed, ", "))
                  end
                  if menu and menu._shelfsync_open and menu.item_table == item_table then menu:updateItems() end
                  UIManager:show(InfoMessage:new { text = table.concat(messages, "\n"),
                    icon = #failed > 0 and "notice-warning" or nil })
                  return
                end
                local engine = target.engine
                if tostring(engine.settings:readBookSetting(document.file, "book_id")) ~= tostring(target.book_id) then
                  table.insert(failed, engine.label)
                  return nextTarget(index + 1)
                end
                engine.cache:queueBookRemoval(document.file, function(ok)
                  table.insert(ok and succeeded or failed, engine.label)
                  if ok then selected[target.key] = nil end
                  nextTarget(index + 1)
                end)
              end
              nextTarget(1)
            end,
          })
        end,
      })
      return items
    end },
    { text = _("Change edition"), sub_item_table = editions },
    { text = _("Jump to a service's position"), sub_item_table = positions },
    { text = _("Service-specific book actions"), sub_item_table = exceptions },
  }
end

function Menus.settings(app)
  local items = app.common_menu:getSubMenuItems()
  local librarything = app.engines.librarything
  local librarything_account = require("shelfsync/lib/librarything/account_ui")
  local hardcover = app.engines.hardcover
  local options = {
    { text = _("LibraryThing read collection"), sub_item_table_func = function()
      return librarything_account.getReadCollectionItems(librarything)
    end },
    { text = _("LibraryThing book source"), sub_item_table_func = function()
      return librarything_account.getAddSourceItems(librarything)
    end },
    { text = _("Hardcover: Suggest a book"), enabled_func = function() return hardcover:isActive() end,
      callback = function() hardcover.provider:showRandomBookDialog() end },
  }
  table.insert(items, { text = _("Service-specific options"), sub_item_table = options })
  return items
end

return Menus
