-- Progress and "finished" updates SyncEngine couldn't send (e.g. while
-- offline), kept until flushPendingUpdates can. Modelled on KOReader's
-- KOSyncQueue, but only holds the latest progress and/or finished per book
-- (by filename), along with the book's link, so nothing is sent for a book
-- that's since been unlinked or relinked.
--
-- There's one file per provider, opened afresh on every access, since a
-- closed reader's plugin instance can still be adding to or sending from it.
local LuaSettings = require("luasettings")

local MAX_AGE = 28 * 24 * 3600 -- 4 weeks, as KOSyncQueue
-- Tries at the date of a finished status the provider has accepted
-- (Goodreads), while connected, before it's given up on. They're an hour
-- apart, so a passing problem, e.g. Goodreads' bot check, doesn't use them all.
local DATE_TRIES = 3
local DATE_RETRY_INTERVAL = 3600

local PendingUpdates = {}
PendingUpdates.__index = PendingUpdates

function PendingUpdates:new(path)
  return setmetatable({ path = path }, self)
end

function PendingUpdates:_load()
  local file = LuaSettings:open(self.path)
  return file, file:readSetting("updates") or {}
end

local function save(file, updates)
  file:saveSetting("updates", next(updates) and updates or nil)
  file:flush()
end

-- filename's entry for `book` (its settings), replacing one for a book it
-- was linked to before.
local function entryFor(updates, filename, book)
  local update = updates[filename]
  if not update or tostring(update.book_id) ~= tostring(book.book_id) then
    update = { book_id = book.book_id }
    updates[filename] = update
  end
  -- Pagebound's API also needs it, and it's gone with the book's settings
  -- if the book's moved or deleted (see SyncEngine:_sendPendingUpdate).
  update.book_uuid = book.book_uuid
  return update
end

-- `book` is nil when updates aren't synced for filename; nothing's queued then.
function PendingUpdates:addProgress(filename, book, value, update_type)
  if not book then return end
  local file, updates = self:_load()
  entryFor(updates, filename, book).progress = {
    value = value,
    update_type = update_type,
    -- Progress, unlike finished, is specific to the edition.
    edition_id = book.edition_id,
    queued_at = os.time(),
  }
  save(file, updates)
end

-- Dated `finished_at`, when the book was finished (by default now), but keeps
-- the date of one already queued.
function PendingUpdates:addFinished(filename, book, finished_at)
  if not book then return end
  local file, updates = self:_load()
  local update = entryFor(updates, filename, book)
  if not update.finished_at then
    update.finished_at = finished_at or os.time()
    update.date_tries, update.date_tried_at = nil, nil
  end
  save(file, updates)
end

-- The link filename's update was queued for, as kept with it.
function PendingUpdates:queuedBook(filename)
  local _, updates = self:_load()
  local update = updates[filename]
  return update and { book_id = update.book_id, book_uuid = update.book_uuid }
end

-- Books with queued updates, least recently tried first.
function PendingUpdates:filenames()
  local _, updates = self:_load()
  local filenames = {}
  for filename in pairs(updates) do
    table.insert(filenames, filename)
  end
  table.sort(filenames, function(a, b)
    return (updates[a].tried_at or 0) < (updates[b].tried_at or 0)
  end)
  return filenames
end

-- filename's queued update, minus whatever no longer applies: all of it if
-- the book isn't linked to the same book any more (`book` is nil when it isn't
-- synced at all), its progress if it's linked to another edition now, and
-- anything queued longer ago than MAX_AGE (or `progress_max_age`).
function PendingUpdates:get(filename, book, progress_max_age)
  local file, updates = self:_load()
  local update = updates[filename]
  if not update then return end

  local now = os.time()
  local linked = book and tostring(book.book_id) == tostring(update.book_id)
  local progress, finished_at = update.progress, update.finished_at
  if progress and not (linked and tostring(progress.edition_id) == tostring(book.edition_id)
      and now - progress.queued_at <= (progress_max_age or MAX_AGE)) then
    update.progress = nil
  end
  if finished_at and not (linked and now - finished_at <= MAX_AGE) then
    update.finished_at = nil
  end

  if update.progress ~= progress or update.finished_at ~= finished_at then
    updates[filename] = (update.progress or update.finished_at) and update or nil
    save(file, updates)
  end
  return updates[filename]
end

-- `sent`, when given, is the queued update before the request started.
-- Don't acknowledge a replacement queued while the request was in flight.
function PendingUpdates:clearProgress(filename, sent)
  local file, updates = self:_load()
  local update = updates[filename]
  local progress = update and update.progress
  if not progress or (sent and (not sent.progress
      or tostring(update.book_id) ~= tostring(sent.book_id)
      or tostring(progress.edition_id) ~= tostring(sent.progress.edition_id)
      or progress.queued_at ~= sent.progress.queued_at
      or progress.value ~= sent.progress.value
      or progress.update_type ~= sent.progress.update_type)) then
    return
  end

  update.progress = nil
  updates[filename] = update.finished_at and update or nil
  save(file, updates)
end

-- Whether `update` still has the finished status `sent` had, if given.
local function finishedAsSent(update, sent)
  return update and update.finished_at and not (sent and (tostring(update.book_id) ~= tostring(sent.book_id)
    or update.finished_at ~= sent.finished_at))
end

function PendingUpdates:clearFinished(filename, sent)
  local file, updates = self:_load()
  local update = updates[filename]
  if not finishedAsSent(update, sent) then return end

  update.finished_at = nil
  updates[filename] = update.progress and update or nil
  save(file, updates)
end

-- Records a failed try at the date of filename's finished status, once the
-- provider has accepted the status. After DATE_TRIES, the finished status is
-- dropped, and the book's left with whatever date the provider gave it.
-- Returns whether it was.
function PendingUpdates:dateNotSet(filename, sent)
  local file, updates = self:_load()
  local update = updates[filename]
  if not finishedAsSent(update, sent) then return false end

  update.date_tries = (update.date_tries or 0) + 1
  update.date_tried_at = os.time()
  local given_up = update.date_tries >= DATE_TRIES
  if given_up then
    update.finished_at, update.date_tries, update.date_tried_at = nil, nil, nil
    updates[filename] = update.progress and update or nil
  end
  save(file, updates)
  return given_up
end

-- Whether the date of `update`'s finished status is due another try, as it
-- is if the clock's been put back since the last.
function PendingUpdates:dateDue(update)
  local since = update.date_tried_at and os.time() - update.date_tried_at
  return not since or since >= DATE_RETRY_INTERVAL or since < 0
end

-- Drops a finished status queued for book_id under another filename, e.g.
-- the one the book had before it was moved or renamed, where its entry stays.
function PendingUpdates:clearFinishedElsewhere(filename, book_id)
  local file, updates = self:_load()
  local changed = false
  for other, update in pairs(updates) do
    if other ~= filename and update.finished_at and tostring(update.book_id) == tostring(book_id) then
      update.finished_at = nil
      updates[other] = update.progress and update or nil
      changed = true
    end
  end
  if changed then save(file, updates) end
end

-- Records a failed attempt, so other books go first next time.
function PendingUpdates:markTried(filename)
  local file, updates = self:_load()
  if not updates[filename] then return end

  updates[filename].tried_at = os.time()
  save(file, updates)
end

return PendingUpdates
