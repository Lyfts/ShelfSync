local _ = require("gettext")
local math = require("math")
local os = require("os")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local UpdateDoubleSpinWidget = require("shelfsync/lib/common/ui/update_double_spin_widget")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")

local STORYGRAPH = require("shelfsync/lib/storygraph/constants")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local ICON = require("shelfsync/lib/common/constants/icons")
local STATUS = require("shelfsync/lib/common/constants/status")

local privacy_labels = {
  [HARDCOVER.PRIVACY.PUBLIC] = "Public",
  [HARDCOVER.PRIVACY.FOLLOWS] = "Follows",
  [HARDCOVER.PRIVACY.PRIVATE] = "Private",
}

local status_choices = {
  { icon = ICON.BOOKMARK, status_id = STATUS.STATUS.TO_READ },
  { icon = ICON.OPEN_BOOK, status_id = STATUS.STATUS.READING },
  { icon = ICON.CHECKMARK, status_id = STATUS.STATUS.FINISHED },
  { icon = ICON.PAUSE, status_id = STATUS.STATUS.PAUSED },
  { icon = ICON.STOP_CIRCLE, status_id = STATUS.STATUS.DNF },
}

local function eligibleProviders(self, status_id)
  local eligible, unsupported = {}, {}
  for _, provider in ipairs(self.providers) do
    local engine = self.engines[provider.key]
    if engine and engine:isActive() and engine.settings:bookLinked() then
      local supported_statuses = provider.constants.SUPPORTED_STATUS_IDS
      if not supported_statuses or supported_statuses[status_id] then
        table.insert(eligible, { provider = provider, engine = engine })
      else
        table.insert(unsupported, { provider = provider, engine = engine })
      end
    end
  end
  return eligible, unsupported
end

local function providerLabels(entries)
  local labels = {}
  for _entry_index, entry in ipairs(entries) do
    table.insert(labels, _(entry.provider.label))
  end
  return table.concat(labels, ", ")
end

local function updateStatusAcrossProviders(self, status_id, menu_instance)
  local filename = self.ui.document and self.ui.document.file
  if not filename then return end

  local eligible, unsupported = eligibleProviders(self, status_id)
  local status_name = _(STATUS.STATUS_NAME[status_id])
  if #eligible == 0 then
    if #unsupported > 0 then
      UIManager:show(InfoMessage:new {
        text = T(_("%1 does not support %2 and was left unchanged."),
          providerLabels(unsupported), status_name),
      })
    end
    return
  end

  local confirmation_text = T(_("Mark this book as %1 on %2?"), status_name, providerLabels(eligible))
  if #unsupported > 0 then
    confirmation_text = confirmation_text .. "\n\n"
      .. T(_("%1 does not support %2 and will be left unchanged."),
        providerLabels(unsupported), status_name)
  end

  eligible[1].engine.dialog_manager:maybeConfirm({
    text = confirmation_text,
    ok_callback = function()
      local item_table = menu_instance and menu_instance.item_table
      local progress_message = InfoMessage:new {
        text = T(_("Updating status on %1..."), providerLabels(eligible)),
      }
      UIManager:show(progress_message)
      local succeeded, unconfirmed, failed = {}, {}, {}
      local remaining = #eligible
      local completed = {}
      local function finish()
        if menu_instance and menu_instance.updateItems and menu_instance.item_table == item_table then
          menu_instance:updateItems()
        end
        UIManager:close(progress_message)

        local messages = {}
        if #succeeded > 0 then
          table.insert(messages, T(_("Updated to %1 on: %2"), status_name, providerLabels(succeeded)))
        end
        if #failed > 0 then
          table.insert(messages, T(_("Could not update %1 on: %2"), status_name, providerLabels(failed)))
        end
        if #unconfirmed > 0 then
          table.insert(messages, T(_("Sent %1 to %2, but its status could not be confirmed."),
            status_name, providerLabels(unconfirmed)))
        end
        if #unsupported > 0 then
          table.insert(messages, T(_("%1 does not support %2 and was left unchanged."),
            providerLabels(unsupported), status_name))
        end
        UIManager:show(InfoMessage:new {
          text = table.concat(messages, "\n"),
          icon = (#failed > 0 or #unconfirmed > 0) and "notice-warning" or nil,
        })
      end
      local function record(entry, saved)
        if completed[entry] then return end
        completed[entry] = true
        local result = entry.engine.state.book_status
        if saved and result and result.status_id == status_id then
          table.insert(succeeded, entry)
        elseif saved
            and entry.provider.constants.WRITE_ONLY_STATUS_IDS
            and entry.provider.constants.WRITE_ONLY_STATUS_IDS[status_id] then
          table.insert(unconfirmed, entry)
        else
          table.insert(failed, entry)
        end
        remaining = remaining - 1
        if remaining == 0 then finish() end
      end
      for _, entry in ipairs(eligible) do
        local call_ok, err = pcall(function()
          entry.engine.cache:queueBookStatus(filename, status_id, function(saved)
            record(entry, saved)
          end)
        end)
        if not call_ok then
          entry.engine.settings:debugWarn(entry.engine.label .. ": status update raised an error: " .. tostring(err))
          record(entry, false)
        end
      end
    end,
    no_confirm_callback = function()
      if menu_instance and menu_instance.updateItems then
        menu_instance:updateItems()
      end
    end,
  })
end

local function sharedStatusItem(self, icon, status_id)
  return {
    text = icon .. " " .. T(_("Set to %1"), _(STATUS.STATUS_NAME[status_id])),
    enabled_func = function()
      local eligible, unsupported = eligibleProviders(self, status_id)
      return #eligible > 0 or #unsupported > 0
    end,
    callback = function(menu_instance)
      updateStatusAcrossProviders(self, status_id, menu_instance)
    end,
    keep_menu_open = true,
  }
end

local function linkStatusLabel(provider, engine)
  if not engine.settings:bookLinked() then
    return T(_("%1: %2"), _(provider.label), _("Not linked"))
  end

  local book_status = engine.state.book_status or {}
  local status_id = book_status.status_id
  local status_name = status_id and provider.constants.STATUS_NAME[status_id]
  local status_label = status_name and _(status_name) or _("Status unknown")
  local method_label = engine.provider:getLinkMethodLabel()
  return T(_("%1: %2 (link method: %3)"), _(provider.label), status_label, method_label)
end

local function linkStatusItems(self)
  local items = {}
  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    local engine = self.engines[current_provider.key]
    table.insert(items, {
      text_func = function()
        return linkStatusLabel(current_provider, engine)
      end,
      callback = function() end,
      keep_menu_open = true,
    })
  end
  return items
end

local function activeLinkedProviders(self)
  local entries = {}
  for _provider_index, provider in ipairs(self.providers) do
    local engine = self.engines[provider.key]
    if engine and engine:isActive() and engine.settings:bookLinked() then
      table.insert(entries, { provider = provider, engine = engine })
    end
  end
  return entries
end

local function removableProviders(self)
  local entries = {}
  for _provider_index, entry in ipairs(activeLinkedProviders(self)) do
    local book_status = entry.engine.state.book_status or {}
    if book_status.id and book_status.status_id then
      table.insert(entries, entry)
    end
  end
  return entries
end

local function providerStatusLabel(entry)
  local book_status = entry.engine.state.book_status or {}
  local status_name = entry.provider.constants.STATUS_NAME[book_status.status_id]
    or _("Status unknown")
  return T(_("%1: %2"), _(entry.provider.label), _(status_name))
end

local function selectedRemovableProviders(self, selected)
  local entries = {}
  for _provider_index, entry in ipairs(removableProviders(self)) do
    if selected[entry.provider.key] then
      table.insert(entries, entry)
    end
  end
  return entries
end

local removeProviderChecklistItems

local function removeSelectedProviders(self, selected, menu_instance)
  local entries = selectedRemovableProviders(self, selected)
  if #entries == 0 then return end
  local item_table = menu_instance and menu_instance.item_table

  entries[1].engine.dialog_manager:maybeConfirm({
    text = T(_("Remove this book from %1? Your local book links will remain."), providerLabels(entries)),
    ok_callback = function()
      local progress_message = InfoMessage:new {
        text = T(_("Removing this book from %1..."), providerLabels(entries)),
      }
      UIManager:show(progress_message)
      local succeeded, failed = {}, {}
      local remaining = #entries
      local completed = {}
      local function finish()
        UIManager:close(progress_message)
        if menu_instance and menu_instance.updateItems and menu_instance.item_table == item_table then
          menu_instance.item_table = removeProviderChecklistItems(self, selected)
          menu_instance:updateItems()
        end

        local messages = {}
        if #succeeded > 0 then
          table.insert(messages, T(_("Removed from: %1"), providerLabels(succeeded)))
        end
        if #failed > 0 then
          table.insert(messages, T(_("Could not remove from: %1"), providerLabels(failed)))
        end
        UIManager:show(InfoMessage:new {
          text = table.concat(messages, "\n"),
          icon = #failed > 0 and "notice-warning" or nil,
        })
      end
      local function record(entry, removed)
        if completed[entry] then return end
        completed[entry] = true
        selected[entry.provider.key] = nil
        if removed then
          table.insert(succeeded, entry)
        else
          entry.engine.settings:debugWarn(entry.engine.label .. ": book removal failed")
          table.insert(failed, entry)
        end
        remaining = remaining - 1
        if remaining == 0 then finish() end
      end
      for _entry_index, entry in ipairs(entries) do
        local call_ok, err = pcall(function()
          entry.engine.cache:queueBookRemoval(self.ui.document.file, function(removed)
            record(entry, removed)
          end)
        end)
        if not call_ok then
          entry.engine.settings:debugWarn(entry.engine.label .. ": book removal raised an error: " .. tostring(err))
          record(entry, false)
        end
      end
    end,
  })
end

removeProviderChecklistItems = function(self, selected)
  local entries = removableProviders(self)
  local items = {}

  if #entries == 0 then
    return { { text = _("No linked provider statuses are available to remove"), enabled = false } }
  end

  for entry_index, entry in ipairs(entries) do
    local current_entry = entry
    local provider_key = current_entry.provider.key
    local item = {
      text_func = function()
        return providerStatusLabel(current_entry)
      end,
      checked_func = function()
        return selected[provider_key] == true
      end,
      callback = function(menu_instance)
        if selected[provider_key] then
          selected[provider_key] = nil
        else
          selected[provider_key] = true
        end
        if menu_instance and menu_instance.updateItems then
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
    }
    if entry_index == #entries then
      item.separator = true
    end
    table.insert(items, item)
  end

  table.insert(items, {
    text = _(ICON.TRASH .. " Remove selected"),
    enabled_func = function()
      return #selectedRemovableProviders(self, selected) > 0
    end,
    callback = function(menu_instance)
      removeSelectedProviders(self, selected, menu_instance)
    end,
    keep_menu_open = true,
  })

  return items
end

local function removeFromProvidersItem(self)
  local selected = {}
  return {
    text = _(ICON.TRASH .. " Remove from providers"),
    enabled_func = function()
      return #activeLinkedProviders(self) > 0
    end,
    sub_item_table_func = function()
      for _provider_index, entry in ipairs(activeLinkedProviders(self)) do
        local status = entry.engine.state.book_status or {}
        if not (status.id and status.status_id) then
          entry.engine.cache:cacheUserBook()
        end
      end
      return removeProviderChecklistItems(self, selected)
    end,
  }
end

local function progressProviders(self, filename)
  local eligible, skipped = {}, {}
  for _provider_index, provider in ipairs(self.providers) do
    local engine = self.engines[provider.key]
    if engine and engine:isActive() and engine.settings:bookLinked() then
      local entry = { provider = provider, engine = engine }
      local book_status = engine.state.book_status or {}
      if book_status.status_id ~= provider.constants.STATUS.READING then
        local status_name = book_status.status_id and provider.constants.STATUS_NAME[book_status.status_id]
        entry.skip_reason = status_name
            and T(_("not currently reading (%1)"), _(status_name))
          or _("reading status is unknown")
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

local function canAddNote(provider, engine)
  if not engine or not engine:isActive() or not engine.settings:bookLinked() then
    return false
  end
  local book_status = engine.state.book_status or {}
  local status_id = book_status.status_id
  if provider.key == "hardcover" then
    return book_status.id ~= nil
  elseif provider.key == "pagebound" then
    return status_id == provider.constants.STATUS.READING
  end

  local status = provider.constants.STATUS
  return status_id ~= nil and status_id ~= status.FINISHED
    and status_id ~= status.DNF and status_id ~= status.TO_READ
end

local function providerNoteItems(self)
  local items = {}
  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    local engine = self.engines[current_provider.key]
    local current_engine = engine
    if canAddNote(current_provider, current_engine) then
      local is_pagebound = current_provider.key == "pagebound"
      table.insert(items, {
        text = T(_("%1: %2"), _(current_provider.label),
          is_pagebound and _("Add forum note") or _("Add journal note")),
        callback = function()
          local book_status = current_engine.state.book_status or {}
          local current_page = current_engine.ui:getCurrentPage()
          local remote_percent
          if current_provider.key == "hardcover" then
            local reads = book_status.user_book_reads
            local current_read = reads and reads[#reads]
            current_page = current_read and current_read.progress_pages or 0
          else
            remote_percent = current_engine.provider:getRemotePercent(book_status) or 0
          end
          current_engine.dialog_manager:journalEntryForm(
            "",
            current_engine.ui.document,
            current_page,
            current_engine.settings:pages(),
            nil,
            remote_percent,
            "note"
          )
        end,
        keep_menu_open = true,
      })
    end
  end
  return items
end

local function addNoteItem(self)
  return {
    text = _("Add note"),
    enabled_func = function()
      return #activeLinkedProviders(self) > 0
    end,
    sub_item_table_func = function()
      for _provider_index, entry in ipairs(activeLinkedProviders(self)) do
        entry.engine.cache:cacheUserBook()
      end
      local items = providerNoteItems(self)
      if #items == 0 then
        return { { text = _("No linked providers can add a note in the current status"), enabled = false } }
      end
      return items
    end,
  }
end

local function storygraphOptionItems(self)
  local items = {
    {
      text = _("Owned"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      checked_func = function()
        return self.state.book_status.is_owned == true
      end,
      callback = function(menu_instance)
        local new_status = not self.state.book_status.is_owned
        local success = self.api:setOwned(self.state.book_status.id, new_status)
        if success then
          self.state.book_status.is_owned = new_status
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
    },
    {
      text = _("Favorite"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      checked_func = function()
        return self.state.book_status.is_favorite == true
      end,
      callback = function(menu_instance)
        local new_status = not self.state.book_status.is_favorite
        local success = self.api:setFavorite(self.state.book_status.id, new_status)
        if success then
          self.state.book_status.is_favorite = new_status
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      separator = true
    },
  }

  local status = self.state.book_status.status_id

  -- Review: only when read or DNF or can_review
  if status and (status == STORYGRAPH.STATUS.FINISHED or status == STORYGRAPH.STATUS.DNF or self.state.book_status.can_review) then
    table.insert(items, {
      text = _("Review"),
      enabled_func = function()
        return self:isActive()
      end,
      sub_item_table_func = function(menu_instance)
        return self:getReviewSubMenuItems(menu_instance)
      end,
      keep_menu_open = true,
      separator = true
    })
  end

  return items
end

local function storygraphReviewItems(self, menu_instance)
  if not self.state.review then
    local existing_review = nil
    if self.state.book_status.review_url then
      local InfoMessage = require("ui/widget/infomessage")
      local info = InfoMessage:new{
        text = _("Fetching existing review..."),
      }
      UIManager:show(info)
      existing_review = self.api:getReview(self.state.book_status.review_url)
      UIManager:close(info)
    end

    if existing_review then
      self.state.review = existing_review
    else
      self.state.review = {
        stars = self.state.book_status.rating or 0,
        pace = "",
        driven = "",
        development = "",
        loveable = "",
        diverse = "",
        flaws = "",
        themes = "",
        thoughts = "",
        mood_ids = {}
      }
    end
  end

  local review = self.state.review
  local book_id = self.state.book_status.id

  local function make_options_items(key, options, menu_instance)
    local sub_items = {}
    for _, opt in ipairs(options) do
      local display_text
      if opt == "" then display_text = "Not selected"
      elseif opt == "n/a" then display_text = "N/A"
      else display_text = opt:gsub("^%l", string.upper)
      end
      table.insert(sub_items, {
        text = display_text,
        radio = true,
        checked_func = function() return review[key] == opt end,
        callback = function()
          review[key] = opt
          if menu_instance and menu_instance.updateItems then
            menu_instance:updateItems()
          end
        end
      })
    end
    return sub_items
  end

  local function get_display_val(val)
    if val == "" then return "Not selected" end
    if val == "n/a" then return "N/A" end
    return val:gsub("^%l", string.upper)
  end

  return {
    {
      text_func = function()
        local stars = review.stars or 0
        local whole = math.floor(stars)
        local star_string = string.rep(ICON.STAR, whole)
        if stars - whole >= 0.25 then star_string = star_string .. ICON.HALF_STAR end
        return "Rating: " .. stars .. " " .. star_string
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = review.stars or 2.5,
          value_min = 0,
          value_max = 5,
          value_step = 0.25,
          value_hold_step = 1,
          precision = "%.2f",
          ok_text = _("Set"),
          title_text = _("Set Rating"),
          callback = function(spin)
            review.stars = spin.value
            menu_instance:updateItems()
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true,
    },
    {
      text = "Moods",
      sub_item_table_func = function(menu_instance)
        local moods = {
          "adventurous", "challenging", "dark", "emotional", "funny",
          "hopeful", "informative", "inspiring", "lighthearted",
          "mysterious", "reflective", "relaxing", "sad", "tense"
        }
        local sub_items = {}
        for i, mood in ipairs(moods) do
          table.insert(sub_items, {
            text = mood:gsub("^%l", string.upper),
            checked_func = function()
              for _, id in ipairs(review.mood_ids) do
                if id == i then return true end
              end
              return false
            end,
            callback = function()
              local found = false
              for idx, id in ipairs(review.mood_ids) do
                if id == i then
                  table.remove(review.mood_ids, idx)
                  found = true
                  break
                end
              end
              if not found then
                table.insert(review.mood_ids, i)
              end
              if menu_instance then menu_instance:updateItems() end
            end,
            keep_menu_open = true,
          })
        end
        return sub_items
      end
    },
    {
      text_func = function() return "Pace: " .. get_display_val(review.pace) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("pace", {"", "slow", "medium", "fast", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Driven by: " .. get_display_val(review.driven) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("driven", {"", "plot", "character", "a mix", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Character Development: " .. get_display_val(review.development) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("development", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Loveable characters: " .. get_display_val(review.loveable) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("loveable", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Diverse cast: " .. get_display_val(review.diverse) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("diverse", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Character flaws: " .. get_display_val(review.flaws) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("flaws", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text = "Themes",
      callback = function(menu_instance)
        local MultiInput = require("ui/widget/multiinputdialog")
        local themes_dialog
        themes_dialog = MultiInput:new {
          title = "Themes (comma separated)",
          fields = {
            {
              text = review.themes,
            }
          },
          buttons = {
            {
              {
                text = _("Cancel"),
                id = "close",
                callback = function()
                  UIManager:close(themes_dialog)
                end,
              },
              {
                text = _("Set"),
                callback = function()
                  review.themes = themes_dialog:getFields()[1]
                  menu_instance:updateItems()
                  UIManager:close(themes_dialog)
                end
              }
            }
          }
        }
        UIManager:show(themes_dialog)
      end,
      keep_menu_open = true,
    },
    {
      text = "Thoughts",
      callback = function(inner_menu)
        local m = inner_menu or menu_instance
        local MultiInput = require("ui/widget/multiinputdialog")
        local thoughts_dialog
        thoughts_dialog = MultiInput:new {
          title = "Your thoughts",
          fields = {
            {
              text = review.thoughts,
              input_type = "text",
            }
          },
          buttons = {
            {
              {
                text = _("Cancel"),
                id = "close",
                callback = function()
                  UIManager:close(thoughts_dialog)
                end,
              },
              {
                text = _("Set"),
                callback = function()
                  review.thoughts = thoughts_dialog:getFields()[1]
                  if m then m:updateItems() end
                  UIManager:close(thoughts_dialog)
                end
              }
            }
          }
        }
        UIManager:show(thoughts_dialog)
      end,
      keep_menu_open = true,
    },
    {
      text = "Save Review",
      callback = function(menu_instance)
        local success = self.api:saveReview(book_id, review, self.state.book_status.review_url)
        if success then
          self.cache:cacheUserBook()
          UIManager:show(InfoMessage:new { text = "Review saved!" })
          self.state.review = nil -- Clear temp state
          menu_instance:onClose()
        else
          UIManager:show(InfoMessage:new { text = "Failed to save review" })
        end
      end
    },
    {
      text = "Cancel Review",
      callback = function(menu_instance)
        self.state.review = nil
        menu_instance:onClose()
      end
    }
  }
end

local function hardcoverVisibilityItems(self)
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

local function hardcoverOptionItems(self)
  local items = {
    {
      text_func = function()
        local reads = self.state.book_status.user_book_reads
        local current_page = reads and reads[#reads] and reads[#reads].progress_pages or 0
        return T(_("Set Hardcover edition page: %1 / %2"), current_page, self.settings:pages() or "?")
      end,
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id == HARDCOVER.STATUS.READING
          and self.settings:pages()
      end,
      callback = function(menu_instance)
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local current_hardcover_page = current_read and current_read.progress_pages or 0
        local document_page = self.ui:getCurrentPage()
        local document_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        local mapped_page = self.page_mapper:getMappedPage(document_page, document_pages, remote_pages)

        local spinner = UpdateDoubleSpinWidget:new {
          ok_always_enabled = true,
          left_text = T(_("Edition page: %1"), current_hardcover_page),
          left_value = mapped_page,
          left_min = 0,
          left_max = remote_pages,
          left_step = 1,
          left_hold_step = 20,
          right_text = _("Local page"),
          right_value = document_page,
          right_min = 0,
          right_max = document_pages,
          right_step = 1,
          right_hold_step = 20,
          update_callback = function(new_edition_page, new_document_page, edition_page_changed)
            if edition_page_changed then
              return new_edition_page,
                self.page_mapper:getUnmappedPage(new_edition_page, document_pages, remote_pages)
            end
            return self.page_mapper:getMappedPage(new_document_page, document_pages, remote_pages),
              new_document_page
          end,
          ok_text = _("Set page"),
          title_text = _("Set Hardcover edition page"),
          callback = function(edition_page)
            local result
            if current_read then
              result = self.api:updatePage(current_read.id, current_read.edition_id, edition_page,
                current_read.started_at)
            else
              result = self.api:createRead(self.state.book_status.id, self.state.book_status.edition_id,
                edition_page, os.date("%Y-%m-%d"))
            end

            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError(_("Page could not be saved"))
            end
          end,
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true,
      separator = true,
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

local option_builders = {
  storygraph = storygraphOptionItems,
  hardcover = hardcoverOptionItems,
}

local UpdateStatusMenu = {}
UpdateStatusMenu.__index = UpdateStatusMenu

function UpdateStatusMenu:new(o)
  return setmetatable(o or {}, self)
end

local function providerContext(provider, engine)
  local context = setmetatable({ [provider.key] = engine.provider }, { __index = engine })
  local option_builder = option_builders[provider.key]
  if option_builder then
    context.getProviderOptionItems = function()
      return option_builder(context)
    end
  end
  if provider.key == "storygraph" then
    context.getReviewSubMenuItems = function(_, menu_instance)
      return storygraphReviewItems(context, menu_instance)
    end
  elseif provider.key == "hardcover" then
    context.getVisibilitySubMenuItems = function()
      return hardcoverVisibilityItems(context)
    end
  end
  return context
end

function UpdateStatusMenu:getSubMenuItems()
  if not self.ui.document then
    return {}
  end

  local menu_items = {}
  for _choice_index, choice in ipairs(status_choices) do
    local item = sharedStatusItem(self, choice.icon, choice.status_id)
    table.insert(menu_items, item)
  end

  table.insert(menu_items, {
    text = _("Link Status"),
    sub_item_table_func = function()
      return linkStatusItems(self)
    end,
  })

  table.insert(menu_items, sharedProgressItem(self))
  table.insert(menu_items, removeFromProvidersItem(self))
  table.insert(menu_items, addNoteItem(self))
  menu_items[#menu_items].separator = true

  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    local engine = self.engines[current_provider.key]
    if option_builders[current_provider.key] then
      local context = providerContext(current_provider, engine)
      table.insert(menu_items, {
        text = _(current_provider.label .. " options"),
        enabled_func = function()
          return engine:isActive() and engine.settings:bookLinked()
        end,
        sub_item_table_func = function()
          engine.cache:cacheUserBook()
          return context:getProviderOptionItems()
        end,
      })
    end
  end

  return menu_items
end

function UpdateStatusMenu:menuItem()
  return {
    text = _("Update status"),
    enabled_func = function()
      return self.ui.document ~= nil
    end,
    sub_item_table_func = function()
      return self:getSubMenuItems()
    end,
  }
end

return UpdateStatusMenu
