-- Unified, cross-provider book review composer: one star rating (quarter-star
-- precision) and one free-text review, submitted to every linked, enabled,
-- authenticated provider at once. Each provider rounds the rating down to whatever
-- precision it actually supports (see each provider.lua's submitReview) --
-- this menu always deals in the full quarter-star value.
--
-- Reached via ShelfSync > Review in the main menu, and via the "book
-- finished" prompt (see main.lua's onShelfSyncBookFinished).
--
-- A compact native ButtonDialog composer. Draft and submission state live here;
-- refreshing controls never reopens the dialog or refreshes provider caches.
local _ = require("gettext")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")

local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")

local ICON = require("shelfsync/lib/common/constants/icons")
local PROVIDERS = require("shelfsync/lib/common/constants/providers")

local Screen = Device.screen

local EMPTY_STAR = "\u{2606}"

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

-- Keep previews on a single paragraph and truncate at a UTF-8 boundary.
local function preview(text, limit)
  local flat = (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local count = 0
  for pos in flat:gmatch("()[%z\1-\127\194-\244]") do
    count = count + 1
    if count > limit then return flat:sub(1, pos - 1) .. "…" end
  end
  return flat
end

function ReviewMenu:_refresh()
  if not self.menu then return end
  -- Update fixed-height controls in place, preserving focus and scroll position.
  for _, row in ipairs(self.menu.buttons) do
    for _, item in ipairs(row) do
      local button = self.menu:getButtonById(item.id)
      if item.multiline then
        -- Button normally starts with a single-line TextWidget and shrinks
        -- long labels. Use a fixed-height text box for these reading areas.
        button.label_widget:free()
        button.text = item.text_func()
        button.label_widget = TextBoxWidget:new {
          text = button.text,
          face = Font:getFace("cfont", item.font_size),
          bold = false,
          alignment = item.align or "center",
          width = button.label_container.dimen.w,
          height = button.label_container.dimen.h,
          height_adjust = false,
          height_overflow_show_ellipsis = true,
          fgcolor = button.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        button.label_container[1] = button.label_widget
      elseif item.text_func then
        button:setText(item.text_func(), button.width)
      end
      if item.enabled_func then button:enableDisable(item.enabled_func()) end
    end
  end
  UIManager:setDirty(self.menu, "ui")
end

function ReviewMenu:_setRating(review)
  UIManager:show(SpinWidget:new {
    value = review.rating or 0,
    value_min = 0,
    value_max = 5,
    value_step = 0.25,
    value_hold_step = 1,
    precision = "%.2f",
    ok_text = _("Set"),
    title_text = _("Set rating"),
    callback = function(spin) review.rating = spin.value end,
    close_callback = function() self:_refresh() end,
  })
end

function ReviewMenu:_ratingHelp()
  UIManager:show(InfoMessage:new {
    text = _([[Set a star rating from 0 to 5 in quarter-star steps.

Each provider rounds this down to whatever precision it actually supports when you submit:
- Goodreads: round down to a whole star
- Hardcover: round down to a half star
- StoryGraph and Fable: exact value (quarter-star precision)]]),
  })
end

function ReviewMenu:_editText(review)
  local dialog
  dialog = InputDialog:new {
    title = _("Your review"),
    input = review.text or "",
    input_hint = _("What stayed with you about this book?"),
    fullscreen = true,
    condensed = true,
    allow_newline = true,
    add_scroll_buttons = true,
    buttons = {{
      {
        text = _("Cancel"),
        id = "close",
        callback = function() UIManager:close(dialog) end,
      },
      {
        text = _("Save draft"),
        callback = function()
          review.text = dialog:getInputText()
          UIManager:close(dialog)
          self:_refresh()
        end,
      },
    }},
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
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

function ReviewMenu:_buttons(review, entries)
  local function selectedCount()
    local count = 0
    for _, entry in ipairs(entries) do
      if entry.eligible and review.selected[entry.key] then count = count + 1 end
    end
    return count
  end
  local buttons = {}
  local stars = {}
  for value = 1, 5 do
    stars[#stars + 1] = {
      id = "star_" .. value,
      text_func = function()
        return (review.rating or 0) >= value and ICON.STAR or EMPTY_STAR
      end,
      font_size = 30,
      callback = function()
        review.rating = value
        self:_refresh()
      end,
      hold_callback = function() self:_ratingHelp() end,
    }
  end
  buttons[#buttons + 1] = stars
  buttons[#buttons + 1] = {
    {
      id = "less", text = "− ¼", font_bold = false,
      enabled_func = function() return (review.rating or 0) > 0 end,
      callback = function()
        review.rating = math.max(0, (review.rating or 0) - 0.25)
        self:_refresh()
      end,
    },
    {
      id = "rating",
      text_func = function()
        return (review.rating or 0) == 0 and _("No rating") or ("%.2f / 5"):format(review.rating)
      end,
      callback = function() self:_setRating(review) end,
      hold_callback = function() self:_ratingHelp() end,
    },
    {
      id = "more", text = "+ ¼", font_bold = false,
      enabled_func = function() return (review.rating or 0) < 5 end,
      callback = function()
        review.rating = math.min(5, (review.rating or 0) + 0.25)
        self:_refresh()
      end,
    },
  }
  buttons[#buttons + 1] = {{
    id = "text",
    text_func = function()
      local excerpt = preview(review.text, 100)
      return excerpt == "" and _("Write a review…") or _("Edit review") .. "\n" .. excerpt
    end,
    align = "left",
    font_size = 18,
    font_bold = false,
    multiline = true,
    height = Screen:scaleBySize(88),
    callback = function() self:_editText(review) end,
  }}
  buttons[#buttons + 1] = {{
    id = "providers_label", text = _("Share with"),
    align = "left", font_size = 16, font_bold = false,
    enabled = false,
  }}
  for i, entry in ipairs(entries) do
    if i % 2 == 1 then buttons[#buttons + 1] = {} end
    table.insert(buttons[#buttons], {
      id = entry.key,
      text_func = function()
        if not entry.eligible then return entry.label .. "\n" .. entry.reason end
        local check = review.selected[entry.key] and ICON.CHECKBOX_CHECKED or ICON.CHECKBOX_UNCHECKED
        return check .. "  " .. entry.label
      end,
      enabled = entry.eligible,
      font_size = 17,
      font_bold = false,
      multiline = true,
      height = Screen:scaleBySize(58),
      callback = function()
        review.selected[entry.key] = not review.selected[entry.key]
        self:_refresh()
      end,
    })
  end
  buttons[#buttons + 1] = {
    {
      id = "close", text = _("Close"), font_bold = false,
      callback = function() self.menu:onClose() end,
    },
    {
      id = "submit",
      text_func = function()
        return _("Submit review") .. " (" .. selectedCount() .. ")"
      end,
      enabled_func = function() return selectedCount() > 0 end,
      callback = function()
        local menu = self.menu
        local eligible = {}
        for _, entry in ipairs(entries) do
          if entry.eligible then eligible[#eligible + 1] = entry end
        end
        if self:_submit(review, eligible) then menu:onClose() end
      end,
    },
  }
  return buttons
end

function ReviewMenu:show()
  if not self.app.ui.document then
    UIManager:show(InfoMessage:new { text = _("Open a book to submit a review.") })
    return
  end

  local review = self:_state()
  local menu
  menu = ButtonDialog:new {
    title = _("Review"),
    title_align = "center",
    use_info_style = false,
    width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9),
    buttons = self:_buttons(review, self:_allEngines()),
    tap_close_callback = function()
      if self.menu == menu then self.menu = nil end
    end,
  }
  self.menu = menu
  self:_refresh()
  UIManager:show(menu)
end

return ReviewMenu
