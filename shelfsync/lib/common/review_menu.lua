-- Unified, cross-provider book review composer: one star rating (quarter-star
-- precision) and one free-text review, submitted to every linked, enabled,
-- authenticated provider at once. Each provider rounds the rating to whatever
-- precision it actually supports (see each provider.lua's submitReview) --
-- this menu always deals in the full quarter-star value.
--
-- Reached via ShelfSync > Review in the main menu, and via the "book
-- finished" prompt (see main.lua's onShelfSyncBookFinished).
--
-- Built on the generic ui/widget/menu.lua Menu (not TouchMenu) -- that widget
-- has no checked_func/keep_menu_open support, and its onMenuSelect
-- unconditionally closes the menu after any leaf item is tapped. Rather than
-- destroying and recreating the whole widget (and re-running the
-- once-per-open network refresh below) on every tap, show() overrides
-- onMenuSelect on the instance to honor a custom `keep_open` item field, same
-- trick as the onMenuHold override further down. Rows that need to stay open
-- (rating, text, provider checkboxes) update state and call
-- self.menu:updateItems() to redraw in place.
local _ = require("gettext")
local Device = require("device")

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")

local ICON = require("shelfsync/lib/common/constants/icons")
local PROVIDERS = require("shelfsync/lib/common/constants/providers")

local Screen = Device.screen

local SECTION_HEADER = "\u{2015}\u{2015}\u{2015} %s \u{2015}\u{2015}\u{2015}"

local ReviewMenu = {}
ReviewMenu.__index = ReviewMenu

function ReviewMenu:new(o)
  return setmetatable(o or {}, self)
end

-- Every provider, with an `eligible` flag and (when not eligible) a `reason`
-- covering the three things that would stop a review from actually
-- reaching it: disabled, not logged in, or this book isn't linked there.
-- `self.app.engines` is keyed by provider.key (see main.lua's
-- ShelfSyncApp:_buildEngine).
function ReviewMenu:_allEngines()
  local result = {}
  for _idx, provider in ipairs(PROVIDERS) do
    local engine = self.app.engines[provider.key]
    local reason
    if not engine.settings:providerEnabled() then
      reason = _("disabled")
    elseif not engine.api:hasCredential() then
      reason = _("not logged in")
    elseif not engine.settings:bookLinked() then
      reason = _("not linked")
    end
    table.insert(result, {
      key = provider.key,
      label = provider.label,
      engine = engine,
      eligible = not reason,
      reason = reason,
    })
  end
  return result
end

function ReviewMenu:_eligibleEngines()
  local result = {}
  for _, entry in ipairs(self:_allEngines()) do
    if entry.eligible then
      table.insert(result, entry)
    end
  end
  return result
end

-- Draft state persists across menu re-opens (so accidentally closing the
-- menu doesn't lose a half-written review), but is reset whenever the open
-- book changes, so a stale draft can't leak onto the wrong book.
function ReviewMenu:_state()
  local filename = self.app.ui.document and self.app.ui.document.file
  if not self.review or self.review_filename ~= filename then
    local eligible = self:_eligibleEngines()
    local selected = {}

    -- Refresh each provider's cached book status once per book-open --
    -- Hardcover and StoryGraph both need a live user_book id
    -- (state.book_status.id) rather than the sidecar-stored book_id, same as
    -- their own menus do before showing anything status-dependent. This is
    -- the only network activity the review menu does before Submit is
    -- actually pressed.
    if #eligible > 0 then
      local loading = InfoMessage:new { text = _("Loading book status...") }
      UIManager:show(loading)
      for _, entry in ipairs(eligible) do
        entry.engine.cache:cacheUserBook()
        selected[entry.key] = true
      end
      UIManager:close(loading)
    end

    self.review = {
      rating = (filename and self.settings:getKoreaderRating(filename)) or 0,
      text = "",
      selected = selected,
    }
    self.review_filename = filename
  end
  return self.review
end

function ReviewMenu:_ratingItem(review)
  return {
    text_func = function()
      local stars = review.rating or 0
      local whole = math.floor(stars)
      local star_string = string.rep(ICON.STAR, whole)
      if stars - whole >= 0.25 then star_string = star_string .. ICON.HALF_STAR end
      return _("Rating: ") .. ("%.2f "):format(stars) .. star_string
    end,
    keep_open = true,
    callback = function()
      local spinner
      spinner = SpinWidget:new {
        value = (review.rating and review.rating > 0) and review.rating or 1,
        value_min = 1,
        value_max = 5,
        value_step = 0.25,
        value_hold_step = 1,
        precision = "%.2f",
        ok_text = _("Set"),
        title_text = _("Set rating"),
        callback = function(spin)
          review.rating = spin.value
        end,
        -- Fires on every dismiss path (Set, Cancel, or tap-outside) -- see
        -- SpinWidget's own onClose(). Using this instead of also updating
        -- from `callback` above avoids redrawing twice on Set.
        close_callback = function()
          self.menu:updateItems()
        end,
      }
      UIManager:show(spinner)
    end,
    hold_callback = function()
      UIManager:show(InfoMessage:new {
        text = _([[Set a star rating from 0 to 5 in quarter-star steps.

Each provider rounds this to whatever precision it actually supports when you submit:
- Goodreads: nearest whole star
- Hardcover: nearest half star
- StoryGraph and Fable: exact value (quarter-star precision)]]),
      })
    end,
  }
end

function ReviewMenu:_textItem(review)
  return {
    text_func = function()
      if not review.text or review.text == "" then
        return _("Review text: (none)")
      end
      local preview = review.text:sub(1, 40)
      if #review.text > 40 then preview = preview .. "..." end
      return _("Review text: ") .. preview
    end,
    keep_open = true,
    callback = function()
      local MultiInputDialog = require("ui/widget/multiinputdialog")
      local dialog
      dialog = MultiInputDialog:new {
        title = _("Review text"),
        fields = {
          { text = review.text, input_type = "text" },
        },
        buttons = {
          {
            {
              text = _("Cancel"),
              id = "close",
              callback = function()
                UIManager:close(dialog)
                self.menu:updateItems()
              end,
            },
            {
              text = _("Set"),
              callback = function()
                review.text = dialog:getFields()[1]
                UIManager:close(dialog)
                self.menu:updateItems()
              end,
            },
          },
        },
      }
      UIManager:show(dialog)
    end,
  }
end

-- Returns true once submission was actually attempted (regardless of
-- per-provider success), false if it bailed out on validation -- the
-- caller uses this to decide whether to close the menu (something happened)
-- or leave it open (nothing changed, let the user fix it).
function ReviewMenu:_submit(review, eligible)
  local selected = {}
  for _, entry in ipairs(eligible) do
    if review.selected[entry.key] then
      table.insert(selected, entry)
    end
  end

  if #selected == 0 then
    UIManager:show(InfoMessage:new { text = _("No providers selected -- review not submitted.") })
    return false
  end

  -- Not tied to any one provider's own wifi state -- reuse StoryGraph's, same
  -- as main.lua's checkForUpdates does for other plugin-wide (not
  -- per-provider) network actions.
  self.app.engines.storygraph.wifi:withWifi(function()
    local filename = self.app.ui.document.file
    local failed = {}
    for _, entry in ipairs(selected) do
      local ok = entry.engine.provider:submitReview(filename, review.rating, review.text)
      if not ok then
        table.insert(failed, entry.label)
      end
    end

    self.review = nil

    if #failed == 0 then
      UIManager:show(InfoMessage:new { text = _("Review submitted!") })
    else
      UIManager:show(InfoMessage:new {
        text = _("Review submitted, but failed for: ") .. table.concat(failed, ", "),
        icon = "notice-warning",
      })
    end
  end)
  return true
end

function ReviewMenu:getSubMenuItems()
  local review = self:_state()
  local all_entries = self:_allEngines()
  local eligible = self:_eligibleEngines()

  local items = {
    self:_ratingItem(review),
    self:_textItem(review),
    { text = SECTION_HEADER:format(_("Providers")), dim = true, select_enabled = false },
  }

  -- All 4 providers are always listed, so it's clear which ones exist and
  -- why a given one can't be reviewed right now -- ineligible ones are
  -- greyed out and untappable (select_enabled = false) rather than hidden.
  -- Checked state is a checkbox glyph in the right-aligned `mandatory`
  -- column (via mandatory_func, so toggling never needs to rebuild the
  -- item_table -- updateItems() alone re-evaluates it).
  for _, entry in ipairs(all_entries) do
    if entry.eligible then
      table.insert(items, {
        text = entry.label,
        mandatory_func = function()
          return review.selected[entry.key] and ICON.CHECKBOX_CHECKED or ICON.CHECKBOX_UNCHECKED
        end,
        keep_open = true,
        callback = function()
          review.selected[entry.key] = not review.selected[entry.key]
          self.menu:updateItems()
        end,
      })
    else
      table.insert(items, {
        text = entry.label,
        mandatory = "(" .. entry.reason .. ")",
        mandatory_dim = true,
        dim = true,
        select_enabled = false,
      })
    end
  end

  table.insert(items, { text = SECTION_HEADER:format(""), dim = true, select_enabled = false })
  table.insert(items, {
    text = _("Submit Review"),
    bold = true,
    keep_open = true,
    callback = function()
      if self:_submit(review, eligible) then
        self.menu.close_callback()
      end
    end,
  })

  return items
end

function ReviewMenu:show()
  if not self.app.ui.document then
    UIManager:show(InfoMessage:new { text = _("Open a book to submit a review.") })
    return
  end

  local menu
  menu = Menu:new {
    title = _("Review"),
    item_table = self:getSubMenuItems(),
    width = Screen:getWidth() - Screen:scaleBySize(50),
    height = Screen:getHeight() - Screen:scaleBySize(100),
    single_line = true,
    close_callback = function()
      UIManager:close(menu)
      self.menu = nil
    end,
  }
  self.menu = menu

  -- The base Menu class always closes itself after any leaf item is chosen
  -- (see the file-level comment above), and separately ignores
  -- item.hold_callback entirely (unlike TouchMenu) -- both overridden here
  -- on the instance rather than the class, so other Menu users are
  -- unaffected.
  menu.onMenuSelect = function(m, item)
    if item.sub_item_table == nil then
      if item.select_enabled == false then
        return true
      end
      if item.select_enabled_func and not item.select_enabled_func() then
        return true
      end
      m:onMenuChoice(item)
      if not item.keep_open and m.close_callback then
        m.close_callback()
      end
    else
      m.item_table.title = m.title
      table.insert(m.item_table_stack, m.item_table)
      m:switchItemTable(item.text, item.sub_item_table)
    end
    return true
  end
  menu.onMenuHold = function(_, item)
    if item.hold_callback then item.hold_callback() end
    return true
  end

  UIManager:show(menu)
end

return ReviewMenu
