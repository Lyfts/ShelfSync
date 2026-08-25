-- Generic reading-progress sync engine, driving one remote provider
-- (StoryGraph or Hardcover) from KOReader's reader lifecycle events. All
-- provider-specific behavior is injected: `label` (display name), `constants`
-- (STATUS/STATUS_NAME table), `api`/`user`/`cache`/`page_mapper`/`wifi`/
-- `dialog_manager`/`settings`/`menu` instances, and a `business` object
-- (StoryGraph or Hardcover) implementing tryAutolink/getRemoteProgress/
-- getRemotePercent/pushProgress. `plugin_settings` is always the single
-- shared (StoryGraph) settings instance, since plugin-update bookkeeping is
-- plugin-wide rather than per-provider.
local _ = require("gettext")
local DocSettings = require("docsettings")
local logger = require("logger")
local math = require("math")

local Event = require("ui/event")
local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local _t = require("shelfsync/lib/common/table_util")
local Scheduler = require("shelfsync/lib/common/scheduler")
local throttle = require("shelfsync/lib/common/throttle")

local SETTING = require("shelfsync/lib/common/constants/settings")

local SyncEngine = {
  enabled = true,
}
SyncEngine.__index = SyncEngine

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
  return self.enabled or self.plugin_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
end

function SyncEngine:disable()
  self.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function SyncEngine:onLink()
  self.business:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end)
end

function SyncEngine:onTrack()
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function SyncEngine:onStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function SyncEngine:onPullPosition()
  if not self.ui.document or not self.settings:bookLinked() then return end

  local book_id = self.settings:getLinkedBookId()

  UIManager:show(Notification:new {
    text = _("Fetching position from " .. self.label .. "..."),
    timeout = 3,
  })

  self.wifi:withWifi(function()
    local status = self.api:findUserBook(book_id, self.user:getId())
    local remote_percent = status and self.business:getRemotePercent(status)
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
      end,
    })
  end)
end

function SyncEngine:onUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    self:updatePageNow(function(result, reason)
      if result then
        UIManager:show(Notification:new {
          text = _("Progress updated")
        })
      else
        logger.warn("Unsuccessful updating page progress", self.ui.document.file, reason)
        UIManager:show(InfoMessage:new {
          text = reason or _("Unable to update reading progress"),
          icon = "notice-warning",
        })
      end
    end)
  else
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
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
  local remote_percent = self.business:getRemotePercent(self.state.book_status) or 0

  if book_id then
    self.wifi:wifiPrompt(function()
      local latest_status = self.api:findUserBook(book_id, self.user:getId())
      local latest_percent = latest_status and self.business:getRemotePercent(latest_status)
      if latest_percent then
        remote_percent = latest_percent
        self.state.book_status = latest_status
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
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.business:tryAutolink()
    end
  elseif field == self.auth_setting_key then
    if change and change ~= "" and not self.enabled then
      self.enabled = true
      self.menu.enabled = true
      self.api.last_auth_warning = nil
      UIManager:show(Notification:new {
        text = _(self.label .. " syncing re-enabled"),
      })
    end
  end
end

-- Called when a page update is skipped because the book's remote status isn't
-- "Currently Reading" (e.g. it was changed on the remote directly while the
-- user kept reading in KOReader). Shown once per document-open session so
-- progress silently going unsynced doesn't go unnoticed.
-- Returns true if the dialog was shown, false if already shown this session.
function SyncEngine:warnStatusMismatch(filename)
  if self.state.status_mismatch_warned then
    self.settings:debugLog(self.label .. ": warnStatusMismatch - already warned this session, skipping")
    return false
  end

  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    self.settings:debugLog(self.label .. ": warnStatusMismatch - no book_id for filename, skipping")
    return false
  end

  self.settings:debugLog(self.label .. ": warnStatusMismatch - showing dialog, status_id="
    .. tostring(self.state.book_status.status_id))
  self.state.status_mismatch_warned = true

  local status_id = self.state.book_status.status_id
  local status_clause = status_id
    and ("This book is marked \"%s\" on " .. self.label):format(self.constants.STATUS_NAME[status_id])
    or ("This book has no status on " .. self.label .. " (it may have been removed from your shelves)")

  self.dialog_manager:confirm({
    text = _(status_clause .. ", so reading progress isn't syncing.\n\nMark it as Currently Reading?"),
    ok_text = _("Mark as Reading"),
    cancel_text = _("Ignore"),
    ok_callback = function()
      self.wifi:withWifi(function()
        self.cache:updateBookStatus(filename, self.constants.STATUS.READING)
        self:registerHighlight()
        if self.state.book_status.status_id == self.constants.STATUS.READING then
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

  if not self:syncFileUpdates(filename) then
    self.settings:debugLog(self.label .. ": _handlePageUpdate - sync disabled for file, skipping")
    return bail(_("Sync is disabled for this book"))
  end

  if self.state.book_status.status_id ~= self.constants.STATUS.READING then
    logger.info(self.label .. ": Skipping page update - status_id is " .. tostring(self.state.book_status.status_id) .. ", not READING")
    if not self:warnStatusMismatch(filename) then
      bail(_("Book is not currently marked as reading on " .. self.label))
    end
    return
  end

  local remote_value = self.business:getRemoteProgress(self.state.book_status, update_type)
  if not immediate and value < remote_value then
    logger.info(self.label .. ": Local progress (" .. value .. " " .. update_type .. ") is behind remote (" .. remote_value .. "). Skipping auto-update.")
    return
  end

  local reads = self.state.book_status.user_book_reads
  local current_read = reads and reads[#reads]
  if not current_read and not self.business.allows_new_read then
    self.settings:debugLog(self.label .. ": _handlePageUpdate - no user_book_reads on book_status, skipping")
    return bail(_("No active reading session found on " .. self.label))
  end

  local immediate_update = function()
    self.wifi:withWifi(function()
      local result, reason = self.business:pushProgress(current_read, value, update_type, filename)
      if result then
        self.state.book_status = result
        self:registerHighlight()
      end
      if callback then
        callback(result, reason)
      end
    end)
  end

  local trapped_update = function()
    Trapper:wrap(immediate_update)
  end

  if immediate then
    immediate_update()
  else
    UIManager:scheduleIn(1, trapped_update)
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
    local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      self.ui.document:getPageCount(),
      self.settings:pages()
    )
    local value, update_type
    if self.settings:syncByRemotePages() and mapped_page then
      value = mapped_page
      update_type = "pages"
    else
      value = math.floor(decimal_percent * 100 + 0.5)
      update_type = "percentage"
    end

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
      local last_percent = math.floor(previous_percent * 100 + 0.5)
      local remote_percent = self.business:getRemoteProgress(self.state.book_status, "percentage")
      if (is_first_check or percentage > last_percent) and percentage >= remote_percent then
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
  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()

  if self.ui.document and (self.settings:bookLinked() or self.settings:autolinkEnabled()) then
    UIManager:scheduleIn(1, self.startReadCache, self)
  end
end

function SyncEngine:cancelPendingUpdates()
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

  if not self.state.book_status.id and not self.settings:syncEnabled() then
    return
  end

  if self.page_update_pending then
    self:updatePageNow()
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
  -- Deliberately doesn't gate on SETTING.ENABLE_WIFI (the "auto-manage wifi"
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

function SyncEngine:updatePageNow(callback, value, update_type)
  if not value then
    local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      self.ui.document:getPageCount(),
      self.settings:pages()
    )
    if self.settings:syncByRemotePages() and mapped_page then
      value = mapped_page
      update_type = "pages"
    else
      value = math.floor(decimal_percent * 100 + 0.5)
      update_type = "percentage"
    end
  end
  self:_handlePageUpdate(self.ui.document.file, value, true, callback, update_type)
end

function SyncEngine:onNetworkDisconnecting()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
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
end

function SyncEngine:onEndOfBook()
  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"

    if action == "pop-up" then
      mark_read = 'later'
    end
  end

  if not mark_read then
    return
  end

  local marker = function()
    self.cache:updateBookStatus(file_path, self.constants.STATUS.FINISHED)
  end

  if mark_read == 'later' then
    UIManager:scheduleIn(30, function()
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" then
        self.wifi:withWifi(function()
          marker()
        end)
      end
    end)
  else
    self.wifi:withWifi(function()
      marker()
      UIManager:show(InfoMessage:new {
        text = _(self.label .. " status saved"),
        timeout = 2
      })
    end)
  end
end

function SyncEngine:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function SyncEngine:onDocSettingsItemsChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local status
  if doc_settings.summary.status == "complete" then
    status = self.constants.STATUS.FINISHED
  elseif doc_settings.summary.status == "reading" then
    status = self.constants.STATUS.READING
  end

  if status then
    self.wifi:withWifi(function()
      self.cache:updateBookStatus(file, status)

      UIManager:show(InfoMessage:new {
        text = _(self.label .. " status saved"),
        timeout = 2
      })
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
  local max_auto_add_attempts = 2

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
        local book_settings = self.settings:readBookSettings(self.ui.document.file) or {}
        if book_settings.book_id then
          if self.state.book_status.id then
            return success()
          else
            self.wifi:withWifi(function()
              if not NetworkManager:isConnected() then
                return restart()
              end

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
              -- as final.
              if not self.state.book_status.status_id then
                if nil_status_attempts < max_nil_status_attempts then
                  nil_status_attempts = nil_status_attempts + 1
                  self.state.book_status = {}
                  return fail("No read status found for book, retrying")
                end

                -- Still genuinely no status after retrying: mirror linkBook()'s
                -- behavior for a freshly-linked book with no status, and add it
                -- as Currently Reading automatically here too, rather than only
                -- ever asking the user to fix it via warnStatusMismatch.
                logger.info(self.label .. ": Already-linked book has no status, adding to Currently Reading automatically")
                local added = self.api:updateUserBook(book_settings.book_id, self.constants.STATUS.READING)
                if added and added.status_id then
                  self.state.book_status = added
                elseif auto_add_attempts < max_auto_add_attempts then
                  -- The write itself can fail transiently (e.g. a momentary
                  -- network hiccup) just as easily as the read above did --
                  -- give it the same kind of retry instead of giving up after
                  -- a single attempt.
                  auto_add_attempts = auto_add_attempts + 1
                  self.state.book_status = {}
                  return fail("Failed to auto-mark book as Currently Reading, retrying")
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
          self.business:tryAutolink(function()
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
    end,

    function()
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from " .. self.label),
        })
      end
    end)
end

function SyncEngine:registerHighlight()
  self.ui.highlight:removeFromHighlightDialog(self.highlight_menu_name)

  if self.settings:bookLinked() then
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
