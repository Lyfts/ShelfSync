local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
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
      local status_id = (engine.state.book_status or {}).status_id
      -- An unknown status means the lookup hasn't returned yet, not that the
      -- book stopped being read. Don't hide the editor behind a pending fetch.
      if status_id and status_id ~= provider.constants.STATUS.READING then
        local status_name = provider.constants.STATUS_NAME[status_id]
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

local function updateProgressAcrossProviders(self, document, chosen_value, targets, skipped, by_percentage)
  local confirmation_lines = {
    by_percentage and T(_("Set progress to %1%?"), chosen_value)
      or T(_("Set progress to local page %1 / %2?"), chosen_value, document:getPageCount()),
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
          target.engine:updateProgressValue(function(result, reason)
            if result then
              table.insert(succeeded, target)
            else
              if reason then
                target.engine.settings:debugWarn(target.engine.label .. ": manual progress update failed")
              end
              table.insert(failed, target)
            end
            updateNextProvider()
          end, target.value, target.update_type)
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

local function pickProgress(self, entries, unchanged, by_percentage)
  local document = self.ui.document
  local total_pages = tonumber(document:getPageCount())
  if not by_percentage and (not total_pages or total_pages <= 0) then
    UIManager:show(InfoMessage:new { text = _("Local page count is unavailable") })
    return
  end

  local current_page = self.ui:getCurrentPage()
  local initial = by_percentage and total_pages and total_pages > 0
    and math.floor(current_page * 100 / total_pages + 0.5) or current_page
  local spinner = SpinWidget:new {
    value = initial,
    value_min = 0,
    value_max = by_percentage and 100 or total_pages,
    value_step = 1,
    value_hold_step = by_percentage and 10 or 20,
    ok_text = _("Preview updates"),
    title_text = by_percentage and _("Set progress percentage") or _("Set current local page"),
    callback = function(spin)
      local chosen = tonumber(spin.value)
      local targets, skipped = {}, unchanged or {}
      for _entry_index, entry in ipairs(entries) do
        local value, update_type, preview_label, reason
        if by_percentage then
          if entry.engine.provider.canPushProgress
              and not entry.engine.provider:canPushProgress("percentage", document.file) then
            reason = _("needs a known edition page count")
          else
            value, update_type = chosen, "percentage"
            preview_label = T(_("%1%"), value)
          end
        else
          local remote_pages
          value, update_type, remote_pages = entry.engine:getProgressTarget(chosen, total_pages)
          if value ~= nil then
            preview_label = progressTargetLabel(value, update_type, remote_pages)
          else
            reason = remote_pages or update_type or _("page mapping is unavailable")
          end
        end
        if reason then
          entry.skip_reason = reason
          table.insert(skipped, entry)
        else
          table.insert(targets, {
            provider = entry.provider,
            engine = entry.engine,
            value = value,
            update_type = update_type,
            preview_label = preview_label,
          })
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
      updateProgressAcrossProviders(self, document, chosen, targets, skipped, by_percentage)
    end,
  }
  UIManager:show(spinner)
end

local function providerProgressDetail(engine)
  local percent = engine.provider.getRemotePercent
    and engine.provider:getRemotePercent(engine.state.book_status)
  if type(percent) == "number" then
    return T(_("%1%"), math.floor(percent + 0.5))
  end
  return _("progress not reported")
end

function Progress:show(mode)
  if not self.ui.document then return end
  local by_percentage = mode == "percentage"
  local eligible, skipped = progressProviders(self, self.ui.document.file)
  if #eligible == 0 then
    UIManager:show(InfoMessage:new {
      text = #skipped > 0 and T(_("No services can be updated. %1"), progressSkippedLabels(skipped))
        or _("Link this book to an active service marked as reading first."),
      icon = "notice-warning",
    })
    return
  end

  local by_key = {}
  for _entry_index, entry in ipairs(eligible) do by_key[entry.provider.key] = entry end
  for _entry_index, entry in ipairs(skipped) do
    if not by_key[entry.provider.key] then by_key[entry.provider.key] = entry end
  end

  local dialog
  local function modeButton(label, selected, next_mode)
    return {
      text = (selected and "☑  " or "☐  ") .. label,
      callback = function()
        dialog:onClose()
        self:show(next_mode)
      end,
    }
  end
  local buttons = {
    {
      modeButton(_("Enter pages"), not by_percentage, "pages"),
      modeButton(_("Enter percentage"), by_percentage, "percentage"),
    },
    {
      {
        text = _("Set all linked services at once"),
        callback = function()
          dialog:onClose()
          pickProgress(self, eligible, skipped, by_percentage)
        end,
      },
    },
  }
  local row = {}
  for _provider_index, provider in ipairs(self.providers) do
    local engine = self.engines[provider.key]
    if engine and engine.settings:bookLinked() then
      local entry = by_key[provider.key]
      local detail
      if not entry then
        detail = _("progress sync unavailable")
      elseif entry.skip_reason then
        detail = entry.skip_reason
      else
        detail = providerProgressDetail(engine)
      end
      table.insert(row, {
        text = _(provider.label) .. ": " .. detail,
        enabled = entry ~= nil and entry.skip_reason == nil,
        callback = function()
          dialog:onClose()
          pickProgress(self, { entry }, nil, by_percentage)
        end,
      })
      if #row == 2 then
        table.insert(buttons, row)
        row = {}
      end
    end
  end
  if #row > 0 then table.insert(buttons, row) end

  dialog = ButtonDialog:new {
    title = _("Edit progress") .. (by_percentage and _(" — Percentage") or _(" — Pages")),
    title_align = "left",
    use_info_style = false,
    width_factor = 0.9,
    rows_per_page = 5,
    buttons = buttons,
  }
  UIManager:show(dialog)
end

return Progress
