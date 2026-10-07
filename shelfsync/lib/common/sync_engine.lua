-- Generic reading-progress sync engine, driving one remote provider
-- (StoryGraph or Hardcover) from KOReader's reader lifecycle events. All
-- provider-specific behavior is injected: `label` (display name), `constants`
-- (STATUS/STATUS_NAME table), `api`/`user`/`cache`/`page_mapper`/`wifi`/
-- `dialog_manager`/`settings` instances, and a `provider` object
-- (StoryGraph or Hardcover) implementing tryAutolink/getRemoteProgress/
-- getRemotePercent/pushProgress. `plugin_settings` is always the single
-- shared (StoryGraph) settings instance, since plugin-update bookkeeping is
-- plugin-wide rather than per-provider.
local _ = require("gettext")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("shelfsync/lib/common/safe_logger")
local math = require("math")

local Event = require("ui/event")
local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local _t = require("shelfsync/lib/common/table_util")
local Book = require("shelfsync/lib/common/book")
local Scheduler = require("shelfsync/lib/common/scheduler")
local throttle = require("shelfsync/lib/common/throttle")

local SETTING = require("shelfsync/lib/common/constants/settings")

local SyncEngine = {
  enabled = true,
}
SyncEngine.__index = SyncEngine

-- Without remote progress to compare against (Goodreads, Fable), older queued
-- progress could undo what's been read on another device since, so it's only
-- sent for a day.
local UNCHECKED_PROGRESS_MAX_AGE = 24 * 3600

function SyncEngine:new(o)
  o = o or {}
  o.state = o.state or {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
  }
  return setmetatable(o, self)
end

function SyncEngine:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

function SyncEngine:isActive()
  return not self:isWikipediaDocument()
    and self.settings:providerEnabled()
    and self.api:hasCredential()
    and (self.enabled or self.plugin_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true)
end

function SyncEngine:isWikipediaDocument()
  return self.ui and self.ui.document
    and Book:isWikipediaDocument(self.ui.document:getProps()) or false
end

function SyncEngine:disable()
  self.enabled = false
  self:registerHighlight()
end

function SyncEngine:onLink()
  if not self:isActive() then return end

  if self.manual_link_dialog then
    self.manual_link_dialog:show(self.provider_key, function(provider, book)
      if not book then
        return
      end
      UIManager:show(Notification:new {
        text = _("Linked to: " .. book.title .. " on " .. provider.label),
      })
    end)
    return
  end

  self.provider:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end)
end

function SyncEngine:onTrack()
  if not self:isActive() then return end

  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function SyncEngine:onStopTrack()
  if not self:isActive() then return end

  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function SyncEngine:onPullPosition()
  if not self:isActive() then return end
  if not self.ui.document or not self.settings:bookLinked() then return end

  local book_id = self.settings:getLinkedBookId()

  UIManager:show(Notification:new {
    text = _("Fetching position from " .. self.label .. "..."),
    timeout = 3,
  })

  self.wifi:withWifi(function(_wifi_enabled, wifi_error)
    if wifi_error then
      UIManager:show(InfoMessage:new {
        text = _("Could not fetch position from " .. self.label .. "."),
        icon = "notice-warning",
      })
      return
    end

    local status = self.api:findUserBook(book_id, self.user:getId())
    local remote_percent = status and self.provider:getRemotePercent(status)
    if not status or not remote_percent then
      UIManager:show(InfoMessage:new {
        text = _("Could not fetch position from " .. self.label .. "."),
        icon = "notice-warning",
      })
      return
    end

    if remote_percent == 0 then
      UIManager:show(InfoMessage:new {
        text = _(self.label .. " shows no progress recorded yet."),
      })
      return
    end

    local document_pages = self.ui.document:getPageCount()
    local target_page = math.max(1, math.floor((remote_percent / 100) * document_pages))

    UIManager:show(ConfirmBox:new {
      text = _(string.format(
        "%s shows %d%% progress.\nJump to page %d of %d?",
        self.label, remote_percent, target_page, document_pages
      )),
      ok_text = _("Jump"),
      ok_callback = function()
        self.ui:handleEvent(Event:new("GotoPage", target_page))
        self.state.book_status = status
        self.state.locally_finished_book_id = nil
      end,
    })
  end)
end

function SyncEngine:onUpdateProgress(completion_callback, gesture_feedback, suppress_provider_feedback)
  -- A provider may still be linked after it is disabled. Skip it silently
  -- before showing gesture feedback or starting any status/progress request.
  -- Keep the sequence moving if a caller is syncing multiple providers.
  if not self:isActive() then
    if completion_callback then
      completion_callback(nil)
    end
    return
  end

  if self.ui.document and self.settings:bookLinked() then
    local function finish(result, reason)
      if not result then
        local http_status = type(reason) == "string"
          and reason:match("[Hh][Tt][Tt][Pp]%s+(%d%d%d)") or "unknown"
        logger.warn("Unsuccessful updating page progress for " .. self.label
          .. " (http_status=" .. http_status
          .. ", reason_length=" .. tostring(type(reason) == "string" and #reason or 0) .. ")")
      end

      if not suppress_provider_feedback then
        if result then
          if gesture_feedback then
            UIManager:show(InfoMessage:new {
              text = _("Progress updated on " .. self.label),
              timeout = 2,
            })
          else
            UIManager:show(Notification:new {
              text = _("Progress updated")
            })
          end
        else
          UIManager:show(InfoMessage:new {
            text = gesture_feedback
              and (reason
                and _("Unable to update reading progress on " .. self.label .. ": " .. reason)
                or _("Unable to update reading progress on " .. self.label))
              or reason or _("Unable to update reading progress"),
            icon = "notice-warning",
          })
        end
      end
      if completion_callback then
        completion_callback(result, reason)
      end
    end

    local function update()
      self:updatePageNow(finish)
    end

    if gesture_feedback and not suppress_provider_feedback then
      UIManager:show(InfoMessage:new {
        text = _("Trying to sync progress to " .. self.label .. "..."),
        timeout = 2,
      })
    end

    -- A gesture can run before startReadCache has populated the remote
    -- status. Refresh an unknown status instead of treating it as proof that
    -- the linked book is not currently reading.
    if gesture_feedback
        and self:isActive()
        and self:syncFileUpdates(self.ui.document.file)
        and not self.state.book_status.status_id then
      self.wifi:withWifi(function(_wifi_enabled, wifi_error)
        if wifi_error then
          return finish(nil, wifi_error)
        end

        local err = self.cache:cacheUserBook()
        self:registerHighlight()
        if err then
          finish(nil, _("Could not fetch book information from " .. self.label))
        else
          update()
        end
      end)
    else
      update()
    end
  else
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    if not suppress_provider_feedback then
      UIManager:show(InfoMessage:new {
        text = error_message,
        icon = "notice-warning",
      })
    end
    if completion_callback then
      completion_callback(nil, error)
    end
  end
end

-- Open note dialog
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function SyncEngine:onNote(note_params)
  if not self:isActive() then return end

  local book_id = self.settings:getLinkedBookId()
  local remote_percent = self.provider:getRemotePercent(self.state.book_status) or 0

  if book_id then
    self.wifi:wifiPrompt(function()
      local latest_status = self.api:findUserBook(book_id, self.user:getId())
      local latest_percent = latest_status and self.provider:getRemotePercent(latest_status)
      if latest_percent then
        remote_percent = latest_percent
        self.state.book_status = latest_status
        self.state.locally_finished_book_id = nil
      end

      self.dialog_manager:journalEntryForm(
        note_params.text,
        self.ui.document,
        note_params.page_number,
        self.settings:pages(),
        note_params.remote_page or nil,
        remote_percent,
        note_params.note_type or "quote"
      )
    end)
    return
  end

  -- Fallback if no book linked
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page or nil,
    remote_percent,
    note_params.note_type or "quote"
  )
end

function SyncEngine:onSettingsChanged(field, change, _original_value)
  -- Drops what's queued for books no longer synced. Disabling the provider
  -- keeps its queued updates; they're just not sent meanwhile.
  if field == SETTING.SHARED.ALWAYS_SYNC then
    for _, filename in ipairs(self.settings.pending_updates:filenames()) do
      -- Not for a book that's been moved or deleted, whose own setting is gone.
      if lfs.attributes(filename, "mode") then
        self.settings.pending_updates:get(filename,
          self:syncFileUpdates(filename) and self.settings:readBookSettings(filename))
      end
    end
  end
  if field == SETTING.BOOKS then
    local book_settings = change.config
    if self:_bookSettingChanged(book_settings, "sync") then
      if book_settings.sync then
        if not self.state.book_status.id then
          self:startReadCache()
        end
      else
        self:cancelPendingUpdates()
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      self:registerHighlight()
    end
  elseif field == SETTING.SHARED.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.SHARED.LINK_BY_IDENTIFIER or field == SETTING.SHARED.LINK_BY_ISBN or field == SETTING.SHARED.LINK_BY_TITLE then
    if change and self:isActive() then
      self.provider:tryAutolink()
    end
  elseif field == SETTING.PROVIDER_ENABLED then
    if change then
      self:registerHighlight()
      if self.ui.document then
        self:startReadCache()
      end
    else
      self:cancelPendingUpdates()
      Scheduler:clear()
      -- Mirrors onSuspend/onNetworkDisconnecting: without resetting this,
      -- startReadCache() on re-enable just aborts as "already started" (it
      -- was never actually torn down), so process_page_turns never gets set
      -- back to true and tracking silently stays dead after a re-enable.
      self.state.read_cache_started = false
      self.state.process_page_turns = false
      self:registerHighlight()
    end
  else
    local auth_setting_changed = field == self.auth_setting_key
    if not auth_setting_changed then
      for _, key in ipairs(self.auth_setting_keys or {}) do
        if field == key then
          auth_setting_changed = true
          break
        end
      end
    end
    if auth_setting_changed then
      if change and change ~= "" and not self.enabled then
        self.enabled = true
        self.api.last_auth_warning = nil
        UIManager:show(Notification:new {
          text = _(self.label .. " syncing re-enabled"),
        })
      end
    end
  end
end

-- Called when a page update is skipped because the book's remote status isn't
-- "Currently Reading" (e.g. it was changed on the remote directly while the
-- user kept reading in KOReader). Shown once per document-open session so
-- progress silently going unsynced doesn't go unnoticed.
-- Returns true if the dialog was shown, false if already shown this session.
function SyncEngine:warnStatusMismatch(filename)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if book_id and self.state.locally_finished_book_id
      and tostring(self.state.locally_finished_book_id) == tostring(book_id)
      and self.state.book_status.status_id == self.constants.STATUS.FINISHED then
    self.settings:debugLog(self.label .. ": warnStatusMismatch - finished status was set locally, skipping")
    return false
  end

  if self.state.status_mismatch_warned then
    self.settings:debugLog(self.label .. ": warnStatusMismatch - already warned this session, skipping")
    return false
  end

  if not book_id then
    self.settings:debugLog(self.label .. ": warnStatusMismatch - no book_id for filename, skipping")
    return false
  end

  self.settings:debugLog(self.label .. ": warnStatusMismatch - showing dialog, status_id="
    .. tostring(self.state.book_status.status_id))
  self.state.status_mismatch_warned = true

  local status_id = self.state.book_status.status_id
  -- `shelf` without a status_id: still shelved, just not on a shelf that maps
  -- to a status (e.g. a custom Goodreads shelf).
  local shelf = self.state.book_status.shelf
  local status_clause = status_id
    and ("This book is marked \"%s\" on " .. self.label):format(self.constants.STATUS_NAME[status_id])
    or shelf and ("This book is on the \"%s\" shelf on " .. self.label .. ", which ShelfSync doesn't track"):format(shelf)
    or ("This book has no status on " .. self.label .. " (it may have been removed from your shelves)")

  self.dialog_manager:confirm({
    text = _(status_clause .. ", so reading progress isn't syncing.\n\nMark it as Currently Reading?"),
    ok_text = _("Mark as Reading"),
    cancel_text = _("Ignore"),
    ok_callback = function()
      self.cache:queueBookStatus(filename, self.constants.STATUS.READING, function(saved)
        self:registerHighlight()
        if saved then
          UIManager:show(Notification:new {
            text = _("Marked as Currently Reading")
          })
        else
          UIManager:show(InfoMessage:new {
            text = _("Failed to update status on " .. self.label),
            icon = "notice-warning",
          })
        end
      end)
    end,
  })

  return true
end

function SyncEngine:_handlePageUpdate(filename, value, immediate, callback, update_type)
  update_type = update_type or "percentage"
  self.page_update_pending = false

  -- Manual (immediate) updates have a caller waiting on feedback; background/throttled
  -- updates are expected to skip silently, so only report a reason for the former.
  local function bail(reason)
    if immediate and callback then
      callback(nil, reason)
    end
  end

  if not self:isActive() then
    self.settings:debugLog(self.label .. ": _handlePageUpdate - provider disabled, skipping")
    return bail(_(self.label .. " is disabled"))
  end

  if not self:syncFileUpdates(filename) then
    self.settings:debugLog(self.label .. ": _handlePageUpdate - sync disabled for file, skipping")
    return bail(_("Sync is disabled for this book"))
  end

  if self.state.book_status.status_id ~= self.constants.STATUS.READING then
    logger.info(self.label .. ": Skipping page update - status_id is " .. tostring(self.state.book_status.status_id) .. ", not READING")
    self:warnStatusMismatch(filename)
    return bail(_("Book is not currently marked as reading on " .. self.label))
  end

  local remote_value = self.provider:getRemoteProgress(self.state.book_status, update_type)
  if not immediate and value < remote_value then
    logger.info(self.label .. ": Local progress (" .. value .. " " .. update_type .. ") is behind remote (" .. remote_value .. "). Skipping auto-update.")
    return
  end

  local reads = self.state.book_status.user_book_reads
  local current_read = reads and reads[#reads]
  if not current_read and not self.provider.allows_new_read then
    self.settings:debugLog(self.label .. ": _handlePageUpdate - no user_book_reads on book_status, skipping")
    return bail(_("No active reading session found on " .. self.label))
  end

  local generation = self.page_update_generation
  local book = self:_syncedBook(filename)
  if not book then
    return bail(_("Book is no longer linked on " .. self.label))
  end
  local book_id, edition_id = book.book_id, book.edition_id
  local function sameBook()
    local linked = self:_syncedBook(filename)
    if linked and tostring(linked.book_id) == tostring(book_id)
        and tostring(linked.edition_id) == tostring(edition_id) then
      return linked
    end
  end
  local function currentBook()
    return generation == self.page_update_generation and self:isActive() and sameBook()
  end

  -- A background update that fails for lack of a network is kept for
  -- flushPendingUpdates; manual ones report the failure instead.
  local function queue()
    if not (immediate and callback) then
      self.settings.pending_updates:addProgress(filename, currentBook(), value, update_type)
    end
  end

  -- Until a background update is sent, closing the book can cancel it (see
  -- _queueClosingProgress). Once a later one, manual or not, is sent, it no
  -- longer needs to be.
  local unsent = { value = value, update_type = update_type, book_id = book_id, edition_id = edition_id }
  local earlier_unsent = self.state.unsent_progress
  local earlier_synced = self.state.synced_progress
  if not (immediate and callback) then
    self.state.unsent_progress = unsent
  end

  local update = function(wifi_error)
    if not currentBook() then return bail(_("Progress update cancelled")) end
    -- A status change or removal that took its turn first can't be undone by
    -- progress allowed by the status before it.
    reads = self.state.book_status.user_book_reads
    current_read = reads and reads[#reads]
    if self.state.book_status.status_id ~= self.constants.STATUS.READING
        or not (current_read or self.provider.allows_new_read) then
      return bail(_("Book is not currently marked as reading on " .. self.label))
    end
    -- Nor can a background update undo progress sent while it waited, e.g.
    -- by a manual update.
    local synced = self.state.synced_progress
    if not immediate and (value < self.provider:getRemoteProgress(self.state.book_status, update_type)
        or synced ~= earlier_synced and synced.update_type == update_type and value < synced.value) then
      logger.info(self.label .. ": Local progress (" .. value .. " " .. update_type .. ") is behind progress sent since. Skipping auto-update.")
      return
    end
    -- Not sent at all, even if Wi-Fi connected without getting online.
    if wifi_error then
      queue()
      return bail(wifi_error)
    end
    local pending = self.settings.pending_updates:get(filename, self:_syncedBook(filename))
    local push_ok, result, reason = xpcall(function()
      return self.provider:pushProgress(current_read, value, update_type, filename)
    end, debug.traceback)
    if not push_ok then
      self.settings:debugWarn(self.label .. ": progress update raised an error")
      result = nil
      reason = _("Progress update failed on " .. self.label)
    end
    if result then
      -- Sent, even if it's been cancelled since (e.g. by a suspend), so
      -- closing the book doesn't queue it again.
      if sameBook() then
        self.state.synced_progress = { value = value, update_type = update_type, book_id = book_id, edition_id = edition_id }
        if self.state.unsent_progress == unsent or self.state.unsent_progress == earlier_unsent then
          self.state.unsent_progress = nil
        end
      end
      if currentBook() then
        self.state.book_status = result
        self.state.locally_finished_book_id = result.status_id == self.constants.STATUS.FINISHED
          and tostring(book_id) or nil
        self:registerHighlight()
      end
      if pending then
        self.settings.pending_updates:clearProgress(filename, pending)
      end
      -- Also the same progress if it was queued while this was being sent,
      -- e.g. as the book was closed.
      local queued = self.settings.pending_updates:get(filename, self.settings:readBookSettings(filename))
      local progress = queued and queued.progress
      if progress and progress.value == value and progress.update_type == update_type
          and tostring(queued.book_id) == tostring(book_id) and tostring(progress.edition_id) == tostring(edition_id) then
        self.settings.pending_updates:clearProgress(filename, queued)
      end
    elseif not NetworkManager:isConnected() then
      queue()
    end
    if callback then
      callback(result, reason)
    end
    self:flushPendingUpdates()
  end

  local immediate_update = function()
    if not currentBook() then return bail(_("Progress update cancelled")) end
    self.cache:serializeUpdate(update)
  end

  if immediate then
    immediate_update()
  else
    UIManager:scheduleIn(1, immediate_update)
  end
end

-- Assigns the throttled page-update wrapper onto this instance (not the
-- shared class table), so two SyncEngine instances running side by side
-- (StoryGraph + Hardcover) each keep their own independent throttle timer
-- instead of clobbering each other's state.
function SyncEngine:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  local throttled_update, cancel_throttle = throttle(track_frequency, function(...)
    self:_handlePageUpdate(...)
  end)
  self._throttledHandlePageUpdate = function(_self, ...) return throttled_update(...) end
  self._cancelPageUpdate = cancel_throttle
end

function SyncEngine:pageUpdateEvent(page)
  local has_baseline = self.state.last_page ~= nil
  self.state.last_page = self.state.page
  self.state.page = page

  if not (self.state.book_status.id and self.settings:syncEnabled()) then
    return
  end
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    local value, update_type = self:_progressValue(self.state.page)

    self.settings:debugLog(self.label .. ": trackByTime check - value=" .. tostring(value) .. " update_type=" .. update_type)
    self:_throttledHandlePageUpdate(self.ui.document.file, value, false, nil, update_type)
    self.page_update_pending = true
  elseif self.settings:trackByProgress() or self.settings:trackByPages() then
    -- No baseline yet this session: sync immediately (mirrors the periodic
    -- throttle's leading-edge fire) instead of silently waiting for a full
    -- interval to be crossed before ever pushing anything.
    local is_first_check = not has_baseline

    local previous_percent, previous_mapped_page = 0, 0
    if not is_first_check then
      previous_percent, previous_mapped_page = self.page_mapper:getRemotePagePercent(
        self.state.last_page,
        document_pages,
        remote_pages
      )
    end

    local current_percent, current_mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local should_sync = is_first_check
    if not should_sync and self.settings:trackByProgress() then
      local percent_interval = self.settings:trackPercentageInterval()
      local last_compare = math.floor(previous_percent * 100 / percent_interval)
      local current_compare = math.floor(current_percent * 100 / percent_interval)
      should_sync = (last_compare ~= current_compare)
    elseif not should_sync and self.settings:trackByPages() then
      local page_step = self.settings:trackPageStep()
      local last_compare = math.floor(previous_mapped_page / page_step)
      local current_compare = math.floor(current_mapped_page / page_step)
      should_sync = (last_compare ~= current_compare)
    end

    logger.info(self.label .. ": progress/pages track check - first=" .. tostring(is_first_check)
      .. " prev%=" .. tostring(previous_percent) .. " cur%=" .. tostring(current_percent)
      .. " should_sync=" .. tostring(should_sync))

    if should_sync then
      local percentage = math.floor(current_percent * 100 + 0.5)
      local remote_percent = self.provider:getRemoteProgress(self.state.book_status, "percentage")
      -- Compare the raw (unrounded) percents here, not values rounded to a
      -- whole percent -- should_sync above can legitimately fire on a
      -- sub-1%-point crossing (e.g. a fine trackPercentageInterval, or a
      -- small trackPageStep on a long book), and rounding both sides to the
      -- same whole percent before comparing would silently swallow the very
      -- push should_sync just asked for, with no log line to show it happened.
      if (is_first_check or current_percent > previous_percent) and percentage >= remote_percent then
        if self.settings:syncByRemotePages() and current_mapped_page then
          self:_handlePageUpdate(self.ui.document.file, current_mapped_page, false, nil, "pages")
        else
          self:_handlePageUpdate(self.ui.document.file, percentage)
        end
      end
    end
  end
end

-- KOReader's paged view mode (the default, and the only mode for fixed-layout
-- documents) only ever broadcasts PageUpdate, never PosUpdate -- the latter
-- is only fired (alongside PageUpdate, for the same page turn) in the
-- reflowable-document scroll/continuous view mode. So PageUpdate, not
-- PosUpdate, is the one event guaranteed to fire on every real page turn
-- regardless of view mode; onPosUpdate is kept only to avoid relying on
-- PageUpdate's page argument alone in scroll mode, and dedupes against it
-- via self.state.page (updated synchronously by onPageUpdate/pageUpdateEvent)
-- so the two don't both trigger a check for the same page turn.
function SyncEngine:onPageUpdate(page)
  if self.state.process_page_turns then
    self:pageUpdateEvent(page)
  end
end

function SyncEngine:onPosUpdate(_, page)
  if self.state.page ~= page then
    self:onPageUpdate(page)
  end
end

function SyncEngine:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function SyncEngine:onReaderReady()
  if self:isWikipediaDocument() then
    self:cancelPendingUpdates()
    Scheduler:clear()
    self.state.read_cache_started = false
    self.state.process_page_turns = false
    self.state.book_status = {}
    self.state.status_mismatch_warned = false
    self.state.locally_finished_book_id = nil
    self.state.page = nil
    self.state.page_map = nil
    self.state.last_page = nil
    self:registerHighlight()
    return
  end

  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()
  self.state.opened_page = self.state.page
  self.state.locally_finished_book_id = nil

  if self.ui.document and (self.settings:bookLinked() or self.settings:autolinkEnabled()) then
    UIManager:scheduleIn(1, self.startReadCache, self)
  end
end

function SyncEngine:cancelPendingUpdates()
  self.page_update_generation = (self.page_update_generation or 0) + 1
  if self._cancelPageUpdate then
    self:_cancelPageUpdate()
  end

  self.page_update_pending = false
end

function SyncEngine:onDocumentClose()
  UIManager:unschedule(self.startReadCache)

  self:cancelPendingUpdates()
  self.state.read_cache_started = false
  self.state.status_mismatch_warned = false
  self.state.locally_finished_book_id = nil

  local ok, err = pcall(self._queueClosingProgress, self)
  if not ok then
    logger.warn(self.label .. ": could not queue progress on close: " .. tostring(err))
  end
  -- Sent once the document has closed, so it isn't skipped as the open book.
  -- That includes progress queued before it was opened, which stays queued
  -- until newer progress is sent, e.g. if it's closed where it was opened.
  if self.settings.pending_updates:queuedBook(self.settings:getFilePath()) then
    UIManager:nextTick(self.flushPendingUpdates, self)
  end

  if not self.state.book_status.id and not self.settings:syncEnabled() then
    return
  end

  self.state.process_page_turns = false
  self.page_update_pending = false
  self.state.book_status = {}
  self.state.page_map = nil
  self.state.last_page = nil
end

function SyncEngine:onSuspend()
  self.settings:debugLog(self.label .. ": onSuspend - cancelling pending updates, read_cache_started was " .. tostring(self.state.read_cache_started))
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false
end

function SyncEngine:onResume()
  -- Deliberately doesn't gate on SETTING.SHARED.ENABLE_WIFI (the "auto-manage wifi"
  -- toggle) -- onSuspend always resets read_cache_started regardless of that
  -- setting, so this needs to always be willing to restart it too, or tracking
  -- stays permanently disarmed after a suspend on devices that manage their
  -- own wifi (mirrors onNetworkConnected's condition below).
  local will_restart = self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started
  self.settings:debugLog(self.label .. ": onResume - will restart read cache = " .. tostring(will_restart))
  if will_restart then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
end

function SyncEngine:getProgressTarget(local_page, document_pages)
  local_page = tonumber(local_page)
  document_pages = tonumber(document_pages)
  if not local_page or not document_pages or document_pages <= 0 then
    return nil, nil, _("Local page count is unavailable")
  end

  local remote_pages = tonumber(self.settings:pages())
  if remote_pages and remote_pages <= 0 then
    remote_pages = nil
  end
  if self.provider.requires_remote_page_count and not remote_pages then
    return nil, nil, _("The linked edition page count is unavailable")
  end
  local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
    local_page,
    document_pages,
    remote_pages
  )
  if self.settings:syncByRemotePages() and remote_pages and mapped_page ~= nil then
    return mapped_page, "pages", remote_pages
  end

  return math.floor((decimal_percent or 0) * 100 + 0.5), "percentage", remote_pages
end

function SyncEngine:updateProgressAtLocalPage(callback, local_page)
  local document = self.ui.document
  if not document then
    if callback then callback(nil, _("No book active")) end
    return
  end

  local value, update_type, err = self:getProgressTarget(local_page, document:getPageCount())
  if value == nil then
    if callback then callback(nil, err) end
    return
  end

  self:_handlePageUpdate(document.file, value, true, callback, update_type)
end

-- Local `page` as the progress value and update_type that get sent.
function SyncEngine:_progressValue(page)
  local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
    page,
    self.ui.document:getPageCount(),
    self.settings:pages()
  )
  if self.settings:syncByRemotePages() and mapped_page then
    return mapped_page, "pages"
  end
  return math.floor((decimal_percent or 0) * 100 + 0.5), "percentage"
end

function SyncEngine:updatePageNow(callback, value, update_type)
  if value == nil then
    local local_page = self.state.page
    if local_page == nil and self.ui and self.ui.getCurrentPage then
      local_page = self.ui:getCurrentPage()
    end
    return self:updateProgressAtLocalPage(callback, local_page)
  end
  if not self.ui.document then
    if callback then callback(nil, _("No book active")) end
    return
  end
  self:_handlePageUpdate(self.ui.document.file, value, true, callback, update_type)
end

-- Queues where the reader left off on close (the document is still open),
-- unless it's been sent already. Covers books read offline, whose page turns
-- aren't tracked because their remote status couldn't be fetched, and the
-- periodic update that closing cancels.
function SyncEngine:_queueClosingProgress()
  local filename = self.settings:getFilePath()
  local book = self:_syncedBook(filename)
  local status_id = self.state.book_status.status_id
  -- Not if the book's known not to be being read there, or to have no status
  -- there since it was removed from the menu. A status that couldn't be read
  -- or set (e.g. offline) is checked when it's sent.
  if not (book and self:isActive()) or (status_id and status_id ~= self.constants.STATUS.READING)
      or self.state.book_status == self.state.removed_status then
    return
  end

  local page = self.ui:getCurrentPage()
  local value, update_type = self:_progressValue(page)
  -- Only what was sent, or left unsent, for the book and edition it's linked
  -- to now, not before it was relinked.
  local function forBook(progress)
    if progress and tostring(progress.book_id) == tostring(book.book_id)
        and tostring(progress.edition_id) == tostring(book.edition_id) then
      return progress
    end
  end
  local synced = forBook(self.state.synced_progress)
  local unsent = forBook(self.state.unsent_progress)
  if self.settings:trackByTime() then
    if page == self.state.opened_page or (synced and synced.value == value and synced.update_type == update_type) then
      return
    end
  -- Progress/page tracking only sends progress forward, when crossing an
  -- interval. So queue where it was left off only if nothing's been sent and
  -- that's further than where the book was opened, or else a crossing that
  -- wasn't sent (cancelled by closing or a suspend, or failed).
  elseif synced or not (self.state.opened_page and page > self.state.opened_page) then
    if not unsent then
      return
    end
    value, update_type = unsent.value, unsent.update_type
  end

  self.settings.pending_updates:addProgress(filename, book, value, update_type)
end

-- Sends queued updates, if any. Like other updates, this goes through
-- AutoWifi, so it only turns Wi-Fi on if "Enable wifi on demand" is set.
-- Then calls `done`, if given, with false if the provider couldn't be reached.
function SyncEngine:flushPendingUpdates(done)
  done = done or function() end
  if not self:isActive() or #self.settings.pending_updates:filenames() == 0 then
    return done()
  end

  self.cache:serializeUpdate(function(wifi_error)
    local ok, sent = true, nil
    if not wifi_error and NetworkManager:isConnected() then
      ok, sent = pcall(self._sendPendingUpdates, self)
    end
    done(ok and sent)
    if not ok then error(sent, 0) end
  end)
end

function SyncEngine:_sendPendingUpdates()
  for _, filename in ipairs(self.settings.pending_updates:filenames()) do
    if not self:_sendPendingUpdate(filename) then
      -- Offline, or the provider's down, so the rest would fail too. This
      -- book goes last next time, so one that keeps failing can't hold up
      -- the others.
      self.settings.pending_updates:markTried(filename)
      return false
    end
  end
  return true
end

-- Sends filename's queued update, read afresh as it may have changed while
-- others were being sent. Returns false if the provider couldn't be reached.
function SyncEngine:_sendPendingUpdate(filename)
  local STATUS = self.constants.STATUS
  local pending_updates = self.settings.pending_updates
  -- filename's queued update, and the book it's for. Nothing while the
  -- provider's turned off, even if only in another plugin instance so far.
  local function queued()
    if not (self:isActive() and self.settings:providerEnabledOnDisk()) then return end
    local book = self:_syncedBook(filename)
    -- A book that's been moved or deleted since took its settings, and so its
    -- link, with it. Its finished status is still sent, to the book it was
    -- queued for, but not its progress, which needs its edition and page count.
    local gone = not book and not lfs.attributes(filename, "mode")
    if gone then
      book = pending_updates:queuedBook(filename)
    end
    local update = pending_updates:get(filename, book,
      self.provider.has_remote_progress == false and UNCHECKED_PROGRESS_MAX_AGE or nil)
    if update and update.progress and gone then
      pending_updates:clearProgress(filename, update)
      update.progress = nil
    end
    if update and update.finished_at and not gone then
      -- Not if it's been marked as reading again in KOReader since, even if
      -- only in the reader it's open in, which may not have saved that yet.
      local reader = filename == self:_openFile() and require("apps/reader/readerui").instance
      local doc_settings = reader and reader.doc_settings or self.settings:getDocSettings(filename)
      local summary = doc_settings:readSetting("summary")
      if not (summary and summary.status == "complete") then
        pending_updates:clearFinished(filename, update)
        update.finished_at = nil
      end
    end
    return update and (update.progress or update.finished_at) and update, book
  end

  local update, book = queued()
  -- The open book's progress is left to live tracking, whose next successful
  -- page update clears it.
  if not update or (not update.finished_at and filename == self:_openFile()) then return true end
  -- Nor is anything sent for a finished status that's only waiting to try its
  -- date again.
  if not update.progress and not pending_updates:dateDue(update) then return true end

  local book_id = update.book_id
  local status, err = self.provider:findUserBookFor(book)
  -- Hardcover skips requests without an error while disconnected.
  if err or not NetworkManager:isConnected() then
    logger.warn(self.label .. ": could not send queued updates, keeping them: " .. tostring(err))
    return false
  end
  status = status or {}

  -- Requests yield: the link, sync setting, open document or queue may have
  -- changed since the lookup began. Never combine one book's status with another's link.
  update, book = queued()
  if not update or tostring(update.book_id) ~= tostring(book_id) then return true end
  -- Without remote progress (Goodreads, Fable), a queued finished status
  -- covers it, and sending 100% first would mark it finished as of today.
  local progress = filename ~= self:_openFile()
    and not (update.finished_at and self.provider.has_remote_progress == false) and update.progress
  if progress then
    local reads = status.user_book_reads
    local current_read = reads and reads[#reads]
    local sendable = self.provider:canPushProgress(progress.update_type, filename)
    if sendable and not status.status_id and not self.provider.has_reliable_status then
      -- e.g. a page that loaded without the user's shelf on it, so try again later.
      logger.info(self.label .. ": Keeping queued progress - the book's status couldn't be read")
    elseif not sendable or status.status_id ~= STATUS.READING or not (current_read or self.provider.allows_new_read)
        or progress.value < self.provider:getRemoteProgress(status, progress.update_type, filename) then
      logger.info(self.label .. ": Dropping queued progress - can't be sent, or the book isn't being read there"
        .. " or is further along")
      pending_updates:clearProgress(filename, update)
    else
      local result = self.provider:pushProgress(current_read, progress.value, progress.update_type, filename, status)
      if result then
        status = result
        pending_updates:clearProgress(filename, update)
      elseif not update.finished_at then
        return false
      end
    end
  end

  update, book = queued()
  if update and tostring(update.book_id) == tostring(book_id) and update.finished_at then
    local already_finished = status.status_id == STATUS.FINISHED
    local result = already_finished and status
      or self.provider:updateUserBookFor(book, STATUS.FINISHED)
    if result then
      pending_updates:clearProgress(filename, update)
      local linked = self:_syncedBook(filename)
      if filename == self.settings:getFilePath() and linked and tostring(linked.book_id) == tostring(book_id) then
        self.state.book_status = result
        self.state.locally_finished_book_id = result.status_id == STATUS.FINISHED
          and tostring(book_id) or nil
        self:registerHighlight()
      end
      -- As Cache:updateBookStatus does: dated when it was finished, and kept
      -- until that date's set too (Goodreads). Then only the date's set, as
      -- the book's already finished there, e.g. when the status was set but
      -- couldn't be read back. A date that can't be set while connected is
      -- only tried a few times, an hour apart (see PendingUpdates:dateNotSet),
      -- even if the status had to be sent again. That's still announced, as
      -- onMarkedFinished does.
      if not pending_updates:dateDue(update) then
        if not already_finished then self.provider:notifyBookFinished(filename) end
        return true
      end
      local dated
      if already_finished then
        dated = self.provider:setDateFinished(book_id, update.finished_at)
      else
        dated = self.provider:onMarkedFinished(book_id, filename, update.finished_at)
      end
      if dated then
        pending_updates:clearFinished(filename, update)
      elseif not NetworkManager:isConnected() then
        return false
      -- Only once the book's shown as finished there. Goodreads takes its bot
      -- check's answer for success, so the status may not have gone through.
      elseif result.status_id == STATUS.FINISHED and pending_updates:dateNotSet(filename, update) then
        logger.info(self.label .. ": Giving up on setting the date a queued finished status was finished")
      end
    elseif not NetworkManager:isConnected() then
      return false
    end
  end
  return true
end

-- The document open in the reader, if any. Not necessarily this instance's:
-- a closed reader's instance, or the file browser's, can be flushing.
function SyncEngine:_openFile()
  local reader = require("apps/reader/readerui").instance
  return reader and reader.document and reader.document.file
end

function SyncEngine:onNetworkDisconnecting()
  if self.settings:readSetting(SETTING.SHARED.ENABLE_WIFI) then
    return
  end

  self.settings:debugLog(self.label .. ": onNetworkDisconnecting - page_update_pending=" .. tostring(self.page_update_pending))
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  if self.page_update_pending and self.ui.document and self.state.book_status.id and self.settings:syncEnabled() and self.settings:trackByTime() then
    self:updatePageNow()
  end
  self.page_update_pending = false
end

function SyncEngine:onNetworkConnected()
  local will_start = self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started
  self.settings:debugLog(self.label .. ": onNetworkConnected - will start read cache = " .. tostring(will_start))
  if will_start then
    self:startReadCache()
  end
  if self.wifi:turnedWifiOn() then
    -- ShelfSync's own connection, for something else, so not retried: a retry
    -- as it's being turned off would turn it on again, and so start this again.
    self:flushPendingUpdates()
  else
    self:_flushAfterConnecting()
  end
end

-- The first requests after connecting can time out, as on a Kindle, and
-- nothing else may send what's queued for a while, so try a few more times
-- while still connected. The first try is right away, ahead of the open book's
-- lookup. Connecting again starts the tries over, and the earlier ones stop.
function SyncEngine:_flushAfterConnecting()
  local round = (self.flush_round or 0) + 1
  self.flush_round = round
  local tries = 0
  local function try()
    tries = tries + 1
    self:flushPendingUpdates(function(sent)
      if sent ~= false or tries == 4 then return end
      -- 4, 8 and then 16 seconds after a failed try.
      UIManager:scheduleIn(2 ^ (tries + 1), function()
        if self.flush_round == round and NetworkManager:isConnected() then try() end
      end)
    end)
  end
  try()
end

function SyncEngine:onEndOfBook()
  if not self:isActive() then return end

  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local mark_read = G_reader_settings:isTrue("end_document_auto_mark")
  local mark_read_later = false

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"
    mark_read_later = action == "pop-up"
  end

  if not mark_read and not mark_read_later then
    return
  end

  -- When it was finished, in case it has to be queued (see _saveBookStatus).
  local finished_at = os.time()
  if mark_read_later then
    local book_id = self.settings:readBookSetting(file_path, "book_id")
    UIManager:scheduleIn(30, function()
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" and self.settings:readBookSetting(file_path, "book_id") == book_id then
        self:_saveBookStatus(file_path, self.constants.STATUS.FINISHED, nil, finished_at)
      end
    end)
  else
    self:_saveBookStatus(file_path, self.constants.STATUS.FINISHED, function(saved)
      if saved then
        UIManager:show(InfoMessage:new {
          text = _(self.label .. " status saved"),
          timeout = 2
        })
      end
    end, finished_at)
  end
end

-- Sets filename's status on the provider and reports whether that worked. A
-- "finished" that couldn't be set is queued for flushPendingUpdates, dated
-- `finished_at` (by default, when this was called) rather than when it failed.
-- Another status replaces a queued "finished", even if it can't be set now.
function SyncEngine:_saveBookStatus(filename, status, callback, finished_at)
  finished_at = finished_at or os.time()
  local book_id = self.settings:readBookSetting(filename, "book_id")
  -- The book can be moved or deleted while this waits to be sent (e.g. by
  -- the "Delete file" end-of-book action), taking its link with it.
  local linked_book = self:_syncedBook(filename)
  -- Not once the provider's turned off, even if only in another plugin
  -- instance so far, e.g. the file browser's once the book's closed.
  local function currentBook()
    local book = self:_syncedBook(filename)
    if self:isActive() and self.settings:providerEnabledOnDisk() and book
        and tostring(book.book_id) == tostring(book_id) then
      return book
    end
  end
  self.cache:serializeUpdate(function(wifi_error)
    local saved = not wifi_error and currentBook() and self.cache:updateBookStatus(filename, status)
    local book = currentBook()
    if not book then
      saved = false
      -- If it's gone, a finished status is queued for the book it was
      -- linked to, like one queued before it went (see _sendPendingUpdate).
      if linked_book and status == self.constants.STATUS.FINISHED and self:isActive()
          and not lfs.attributes(filename, "mode") then
        self.settings.pending_updates:addFinished(filename, linked_book, finished_at)
        if not wifi_error then
          self:flushPendingUpdates()
        end
      end
    elseif not saved then
      logger.warn(self.label .. ": could not update book status: " .. tostring(wifi_error or "request failed"))
      if status == self.constants.STATUS.FINISHED then
        self.settings.pending_updates:addFinished(filename, book, finished_at)
      end
    end
    local pending = book and status ~= self.constants.STATUS.FINISHED
      and self.settings.pending_updates:get(filename, book)
    if pending then
      self.settings.pending_updates:clearFinished(filename, pending)
    end
    if book and status ~= self.constants.STATUS.FINISHED then
      self.settings.pending_updates:clearFinishedElsewhere(filename, book.book_id)
    end
    if callback then callback(saved) end
  end)
end

function SyncEngine:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

-- filename's book settings, if its updates are synced.
function SyncEngine:_syncedBook(filename)
  if self.settings:providerEnabled() and self:syncFileUpdates(filename) then
    return self.settings:readBookSettings(filename)
  end
end

function SyncEngine:onDocSettingsItemsChanged(file, doc_settings)
  if not self:isActive() or not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local status
  if doc_settings.summary.status == "complete" then
    status = self.constants.STATUS.FINISHED
  elseif doc_settings.summary.status == "reading" then
    status = self.constants.STATUS.READING
  end

  if status then
    self:_saveBookStatus(file, status, function(saved)
      if saved then
        UIManager:show(InfoMessage:new {
          text = _(self.label .. " status saved"),
          timeout = 2
        })
      end
    end)
  end
end

function SyncEngine:startReadCache()
  logger.info(self.label .. ": startReadCache triggered")
  if not self:isActive() then
    logger.info(self.label .. ": startReadCache aborted - app not active")
    return
  end

  if self.state.read_cache_started then
    logger.info(self.label .. ": startReadCache aborted - already started")
    return
  end

  if not self.ui.document then
    return
  end

  self.state.read_cache_started = true

  local cancel
  local nil_status_attempts = 0
  local max_nil_status_attempts = 2
  local auto_add_attempts = 0
  local max_auto_add_retries = 3

  local restart = function(delay)
    delay = delay or 60
    self.settings:debugLog(self.label .. ": startReadCache restart() - rescheduling in " .. delay .. "s")
    cancel()
    self.state.read_cache_started = false
    UIManager:scheduleIn(delay, self.startReadCache, self)
  end

  cancel = Scheduler:withRetries(6, 3, function(success, fail)
      Trapper:wrap(function()
        if not self.ui.document then
          -- fail, but cancel retries
          return success()
        end
        local document = self.ui.document
        local filename = document.file
        local book_settings = self.settings:readBookSettings(filename) or {}
        if book_settings.book_id then
          -- A cached book id only proves that the book page was found. Keep
          -- retrying when its shelf status is missing so transient readback
          -- and CSRF failures can recover without asking the user to update
          -- the status manually.
          if self.state.book_status.id and self.state.book_status.status_id then
            return success()
          else
            -- In turn with this provider's other updates, so the lookup and
            -- the automatic Currently Reading below can't cross a queued or
            -- manual status change for the book.
            self.cache:serializeUpdate(function(wifi_error)
              -- Wi-Fi restoration can take long enough for the reader to
              -- close this book or open another one. Don't let a stale cache
              -- request act on the new document (or on no document at all).
              if self.ui.document ~= document then
                return
              end

              -- Set while this waited, e.g. by sending a queued finished
              -- status, which a lagging read could otherwise undo below.
              if self.state.book_status.id and self.state.book_status.status_id then
                return success()
              end

              if wifi_error then
                return fail(wifi_error)
              end

              if not NetworkManager:isConnected() then
                return fail("Network not connected")
              end

              -- AutoWifi wraps delayed callbacks in Trapper and holds the
              -- shared Wi-Fi lease until cacheUserBook has returned.
              local err = self.cache:cacheUserBook()
              self:registerHighlight()
              logger.info(self.label .. ": startReadCache - cacheUserBook completed, status=" .. (self.state.book_status.status_id or "nil"))
              if err then
                return fail(err)
              end

              -- A nil status_id here (fetched the book page fine, but found no
              -- read-status on it) is usually a real, stable outcome -- e.g. the
              -- book was removed from the user's shelves, or its status was
              -- changed to something we don't render a badge for -- rather than a
              -- fetch failure to retry indefinitely. But a single miss can also be
              -- a one-off render/parse blip on an otherwise normal "Currently
              -- Reading" book, so give it a couple of retries before accepting it
              -- as final. A book that findUserBook reports as still `shelved`,
              -- just on a shelf with no matching status, is left where it is.
              if not self.state.book_status.status_id and not self.state.book_status.shelved then
                if nil_status_attempts < max_nil_status_attempts then
                  nil_status_attempts = nil_status_attempts + 1
                  self.state.book_status = {}
                  -- The page loaded successfully, so a short retry can
                  -- distinguish a temporary parse/readback miss from a
                  -- stable no-status result. Network errors keep the normal
                  -- exponential backoff below.
                  return fail(2)
                end

                -- Not for a book KOReader has marked as finished, which may
                -- just have had its queued finished status sent, by the file
                -- browser or a closed reader, and read back empty.
                local summary = self.settings:getDocSettings(filename):readSetting("summary")
                if summary and summary.status == "complete" then
                  logger.info(self.label .. ": Already-linked book has no status, but is finished, not adding it to Currently Reading")
                  return success()
                end

                -- Still genuinely no status after retrying: mirror linkBook()'s
                -- behavior for a freshly-linked book with no status, and add it
                -- as Currently Reading automatically here too, rather than only
                -- ever asking the user to fix it via warnStatusMismatch.
                logger.info(self.label .. ": Already-linked book has no status, adding to Currently Reading automatically")
                local added = self.api:updateUserBook(book_settings.book_id, self.constants.STATUS.READING)
                if added and added.status_id then
                  self.state.book_status = added
                  self.state.locally_finished_book_id = nil
                elseif auto_add_attempts < max_auto_add_retries then
                  -- The write itself can fail transiently (e.g. a momentary
                  -- network hiccup) just as easily as the read above did --
                  -- retry a few times with a short exponential delay instead
                  -- of waiting for the generic network-error backoff.
                  auto_add_attempts = auto_add_attempts + 1
                  self.state.book_status = {}
                  return fail(2 ^ auto_add_attempts)
                end
                -- Still no status after retrying the write too: fall through
                -- to success() with an empty book_status. warnStatusMismatch
                -- (from _handlePageUpdate) remains the safety net to let the
                -- user fix it manually.
              end

              success()
              self:registerHighlight() -- redundant but safe
            end)
          end
        else
          -- tryAutolink's `done` fires once linking is fully resolved, even
          -- when it had to wait on a wifi restore first (see AutoWifi:withWifi).
          -- Checking bookLinked() synchronously right after the call would
          -- miss that case: this retry chain would die silently -- with
          -- nothing left to ever restart it -- while the actual link still
          -- went through moments later, unobserved. A miss (no match, or
          -- autolink not enabled) isn't a transient failure worth retrying,
          -- so it's not routed through fail() -- same as the synchronous
          -- no-match case, this chain simply ends here.
          self.provider:tryAutolink(function()
            if self.settings:bookLinked() and self.settings:syncEnabled() then
              restart(2)
            end
          end)
          return
        end
      end)
    end,

    function()
      if self.settings:syncEnabled() then
        self.state.process_page_turns = true

        if self.settings:syncOnOpen() then
          -- Try a sync right away, using the current position, rather than
          -- waiting for the first page turn (or a full trackByTime interval)
          -- to elapse. pageUpdateEvent's existing "no baseline yet" and
          -- remote-behind guards mean this quietly no-ops if there's nothing
          -- new to push; subsequent page turns fall back to the usual
          -- periodic/threshold sync pattern.
          self:pageUpdateEvent(self.state.page)
        end
      end

      -- Send what was queued while the network was unavailable.
      if NetworkManager:isConnected() then
        self:flushPendingUpdates()
      end
    end,

    function()
      self.state.read_cache_started = false
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from " .. self.label),
        })
      end
    end)
end

function SyncEngine:registerHighlight()
  -- Provider settings can be changed from KOReader's file browser, where the
  -- reader-only highlight module has not been loaded yet. Reader lifecycle
  -- callbacks will register the action once the book is opened.
  if not self.ui or not self.ui.highlight then
    return
  end

  self.ui.highlight:removeFromHighlightDialog(self.highlight_menu_name)

  if self.settings:bookLinked() and not self:isWikipediaDocument() then
    self.ui.highlight:addToHighlightDialog(self.highlight_menu_name, function(this)
      return {
        text_func = function()
          return _(self.label .. ": Add note")
        end,
        enabled_func = function()
          local status = self.state.book_status.status_id
          return self:isActive() and status and status ~= self.constants.STATUS.FINISHED
            and status ~= self.constants.STATUS.DNF and status ~= self.constants.STATUS.TO_READ
        end,
        callback = function()
          if not self:isActive() then return end
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

return SyncEngine
