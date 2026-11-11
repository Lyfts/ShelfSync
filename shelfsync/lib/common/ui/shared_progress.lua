local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")

local Progress = {}
Progress.__index = Progress
function Progress:new(o) return setmetatable(o or {}, self) end

local function providerLabels(entries)
  local labels = {}
  for _entry_index, entry in ipairs(entries) do
    table.insert(labels, _(entry.provider.label))
  end
  return table.concat(labels, ", ")
end

local function progressProviders(self, filename)
  local eligible, skipped = {}, {}
  for _provider_index, provider in ipairs(self.providers) do
    local engine = self.engines[provider.key]
    if engine and engine.provider.tracks_progress ~= false and engine:isActive() and engine.settings:bookLinked() then
      local entry = { provider = provider, engine = engine }
      local book_status = engine.state.book_status or {}
      if book_status.status_id ~= provider.constants.STATUS.READING then
        local status_name = book_status.status_id and provider.constants.STATUS_NAME[book_status.status_id]
        entry.skip_reason = status_name
            and T(_("not currently reading (%1)"), _(status_name))
          or _("reading status is unknown; use Sync now to refresh it")
        table.insert(skipped, entry)
      elseif engine.provider.requires_remote_page_count
          and (not tonumber(engine.settings:pages()) or tonumber(engine.settings:pages()) <= 0) then
        entry.skip_reason = _("linked edition page count is unavailable")
        table.insert(skipped, entry)
      elseif not engine:syncFileUpdates(filename) then
        entry.skip_reason = _("sync is disabled for this book")
        table.insert(skipped, entry)
      else
        table.insert(eligible, entry)
      end
    end
  end
  return eligible, skipped
end

local function progressTargetLabel(value, update_type, remote_pages)
  if update_type == "pages" then
    return T(_("Page %1 / %2"), value, remote_pages or "?")
  end
  return T(_("%1%"), value)
end

local function progressSkippedLabels(entries)
  local labels = {}
  for _entry_index, entry in ipairs(entries) do
    table.insert(labels, T(_("%1 (%2)"), _(entry.provider.label), entry.skip_reason))
  end
  return table.concat(labels, ", ")
end

local function updateProgressAcrossProviders(self, document, local_page, targets, skipped, menu_instance)
  local confirmation_lines = {
    T(_("Set progress to local page %1 / %2?"), local_page, document:getPageCount()),
  }
  local moves_backwards = {}
  for _target_index, target in ipairs(targets) do
    table.insert(confirmation_lines, T(_("%1: %2"),
      _(target.provider.label), target.preview_label))
    local remote_progress = tonumber(target.engine.provider:getRemoteProgress(
      target.engine.state.book_status, target.update_type
    ))
    if remote_progress and target.value < remote_progress then
      table.insert(moves_backwards, target)
    end
  end
  if #moves_backwards > 0 then
    table.insert(confirmation_lines, "\n" .. T(_("This moves progress backward on: %1"), providerLabels(moves_backwards)))
  end
  if #skipped > 0 then
    table.insert(confirmation_lines, "\n" .. T(_("Will be left unchanged: %1"), progressSkippedLabels(skipped)))
  end

  local confirmation_dialog = targets[1].engine.dialog_manager
  local confirm_options = {
    text = table.concat(confirmation_lines, "\n"),
    ok_callback = function()
      local progress_message = InfoMessage:new {
        text = T(_("Updating progress on %1..."), providerLabels(targets)),
      }
      UIManager:show(progress_message)

      local succeeded, failed = {}, {}
      local stopped = {}
      local target_index = 1
      local function finish()
        UIManager:close(progress_message)
        if menu_instance and menu_instance.updateItems then
          menu_instance:updateItems()
        end

        local messages = {}
        if #succeeded > 0 then
          table.insert(messages, T(_("Updated progress on: %1"), providerLabels(succeeded)))
        end
        if #failed > 0 then
          table.insert(messages, T(_("Could not update progress on: %1"), providerLabels(failed)))
        end
        if #stopped > 0 then
          table.insert(messages, T(_("Stopped before updating: %1"), providerLabels(stopped)))
        end
        if #skipped > 0 then
          table.insert(messages, T(_("Left unchanged: %1"), progressSkippedLabels(skipped)))
        end
        UIManager:show(InfoMessage:new {
          text = table.concat(messages, "\n"),
          icon = (#failed > 0 or #stopped > 0) and "notice-warning" or nil,
        })
      end

      local function updateNextProvider()
        if target_index > #targets then
          finish()
          return
        end
        if self.ui.document ~= document then
          while target_index <= #targets do
            table.insert(stopped, targets[target_index])
            target_index = target_index + 1
          end
          finish()
          return
        end

        local target = targets[target_index]
        target_index = target_index + 1
        local call_ok = xpcall(function()
          target.engine:updateProgressAtLocalPage(function(result, reason)
            if result then
              table.insert(succeeded, target)
            else
              if reason then
                target.engine.settings:debugWarn(target.engine.label .. ": manual progress update failed")
              end
              table.insert(failed, target)
            end
            updateNextProvider()
          end, local_page)
        end, debug.traceback)
        if not call_ok then
          target.engine.settings:debugWarn(target.engine.label .. ": manual progress update raised an error")
          table.insert(failed, target)
          updateNextProvider()
        end
      end

      updateNextProvider()
    end,
  }
  if #moves_backwards > 0 then
    confirmation_dialog:confirm(confirm_options)
  else
    confirmation_dialog:maybeConfirm(confirm_options)
  end
end

local function sharedProgressItem(self)
  local function eligibleProviders()
    if not self.ui.document then return {}, {} end
    return progressProviders(self, self.ui.document.file)
  end

  return {
    text_func = function()
      local document = self.ui.document
      local current_page = self.ui:getCurrentPage()
      local total_pages = document and document:getPageCount() or "?"
      return T(_("Update progress: Page %1 / %2"), current_page, total_pages)
    end,
    enabled_func = function()
      local eligible = eligibleProviders()
      return #eligible > 0
    end,
    callback = function(menu_instance)
      local document = self.ui.document
      if not document then return end
      local total_pages = tonumber(document:getPageCount())
      if not total_pages or total_pages <= 0 then
        UIManager:show(InfoMessage:new { text = _("Local page count is unavailable") })
        return
      end

      local current_page = self.ui:getCurrentPage()
      local spinner = SpinWidget:new {
        value = current_page,
        value_min = 0,
        value_max = total_pages,
        value_step = 1,
        value_hold_step = 20,
        ok_text = _("Preview updates"),
        title_text = _("Set current local page"),
        callback = function(spin)
          local local_page = tonumber(spin.value)
          local eligible, skipped = progressProviders(self, document.file)
          local targets = {}
          for _provider_index, entry in ipairs(eligible) do
            local value, update_type, remote_pages = entry.engine:getProgressTarget(local_page, total_pages)
            if value ~= nil then
              local target = {
                provider = entry.provider,
                engine = entry.engine,
                value = value,
                update_type = update_type,
                preview_label = progressTargetLabel(value, update_type, remote_pages),
              }
              table.insert(targets, target)
            else
              entry.skip_reason = remote_pages or update_type or _("page mapping is unavailable")
              table.insert(skipped, entry)
            end
          end

          if #targets == 0 then
            UIManager:show(InfoMessage:new {
              text = #skipped > 0
                and T(_("No providers can be updated. %1"), progressSkippedLabels(skipped))
                or _("No linked providers are currently marked as reading"),
              icon = "notice-warning",
            })
            return
          end
          updateProgressAcrossProviders(self, document, local_page, targets, skipped, menu_instance)
        end,
      }
      UIManager:show(spinner)
    end,
    keep_menu_open = true,
  }
end

function Progress:show()
  if not self.ui.document then return end
  local eligible, skipped = progressProviders(self, self.ui.document.file)
  if #eligible == 0 then
    UIManager:show(InfoMessage:new {
      text = #skipped > 0 and T(_("No services can be updated. %1"), progressSkippedLabels(skipped))
        or _("Link this book to an active service marked as reading first."),
      icon = "notice-warning",
    })
    return
  end
  local item = sharedProgressItem(self)
  item.callback(nil)
end

return Progress
