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
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local FABLE = require("shelfsync/lib/fable/constants")
local PAGEBOUND = require("shelfsync/lib/pagebound/constants")
local ICON = require("shelfsync/lib/common/constants/icons")

local privacy_labels = {
  [HARDCOVER.PRIVACY.PUBLIC] = "Public",
  [HARDCOVER.PRIVACY.FOLLOWS] = "Follows",
  [HARDCOVER.PRIVACY.PRIVATE] = "Private",
}

local function storygraphStatusItem(self, icon, status_id)
  return {
    text = _(icon .. " " .. STORYGRAPH.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(STORYGRAPH.STATUS_NAME[status_id]),
        ok_callback = function()
          self.cache:updateBookStatus(self.ui.document.file, status_id)
          menu_instance.item_table = self:getStatusSubMenuItems()
          menu_instance:updateItems()
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
  }
end

local function storygraphStatusItems(self)
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, STORYGRAPH.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, STORYGRAPH.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, STORYGRAPH.STATUS.FINISHED),
    self:_statusMenuItem(ICON.PAUSE, STORYGRAPH.STATUS.PAUSED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, STORYGRAPH.STATUS.DNF),
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = self.api:removeRead(self.state.book_status.id)
            if result then
              self.state.book_status = {}
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
    },
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

  -- Update progress: only when NOT read, DNF, removed, or want to read
  if status and status ~= STORYGRAPH.STATUS.FINISHED and status ~= STORYGRAPH.STATUS.DNF and status ~= STORYGRAPH.STATUS.TO_READ then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.state.book_status.last_reached_percent or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

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

local function hardcoverStatusItem(self, icon, status_id)
  return {
    text = _(icon .. " " .. HARDCOVER.STATUS_NAME[status_id]),
    enabled_func = function()
      return self:isActive()
    end,
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(HARDCOVER.STATUS_NAME[status_id]),
        ok_callback = function()
          self.cache:updateBookStatus(self.ui.document.file, status_id)
          menu_instance.item_table = self:getStatusSubMenuItems()
          menu_instance:updateItems()
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
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

local function hardcoverStatusItems(self)
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, HARDCOVER.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, HARDCOVER.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, HARDCOVER.STATUS.FINISHED),
    self:_statusMenuItem(ICON.PAUSE, HARDCOVER.STATUS.PAUSED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, HARDCOVER.STATUS.DNF),
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = self.api:removeRead(self.state.book_status.id)
            if result then
              self.state.book_status = {}
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text_func = function()
        local reads = self.state.book_status.user_book_reads
        local current_page = reads and reads[#reads] and reads[#reads].progress_pages or 0
        local max_pages = self.settings:pages()

        if not max_pages then
          max_pages = "???"
        end

        return T(_("Update page: %1 of %2"), current_page, max_pages)
      end,
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id == HARDCOVER.STATUS.READING and self.settings:pages()
      end,
      callback = function(menu_instance)
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local last_hardcover_page = current_read and current_read.progress_pages or 0

        local document_page = self.ui:getCurrentPage()
        local document_pages = self.ui.document:getPageCount()

        local remote_pages = self.settings:pages()
        local mapped_page = self.page_mapper:getMappedPage(document_page, document_pages, remote_pages)

        local left_text = "Edition"
        if last_hardcover_page > 0 then
          left_text = left_text .. ": was " .. last_hardcover_page
        end

        local spinner = UpdateDoubleSpinWidget:new {
          ok_always_enabled = true,

          left_text = left_text,
          left_value = mapped_page,
          left_min = 0,
          left_max = remote_pages,
          left_step = 1,
          left_hold_step = 20,

          right_text = "Local page",
          right_value = document_page,
          right_min = 0,
          right_max = document_pages,
          right_step = 1,
          right_hold_step = 20,

          update_callback = function(new_edition_page, new_document_page, edition_page_changed)
            if edition_page_changed then
              local new_mapped_page = self.page_mapper:getUnmappedPage(new_edition_page, document_pages, remote_pages)
              return new_edition_page, new_mapped_page
            else
              local new_mapped_page = self.page_mapper:getMappedPage(new_document_page, document_pages, remote_pages)
              return new_mapped_page, new_document_page
            end
          end,
          ok_text = _("Set page"),
          title_text = _("Set current page"),

          callback = function(edition_page, _document_page)
            local result

            if current_read then
              result = self.api:updatePage(current_read.id, current_read.edition_id, edition_page,
                current_read.started_at)
            else
              local start_date = os.date("%Y-%m-%d")
              result = self.api:createRead(self.state.book_status.id, self.state.book_status.edition_id, edition_page,
                start_date)
            end

            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError("Page could not be saved")
            end
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = _("Add a note"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.id ~= nil
      end,
      callback = function()
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local current_page = current_read and current_read.progress_pages or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          nil,
          "note"
        )
      end,
      keep_menu_open = true
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

local function goodreadsStatusItem(self, icon, status_id)
  return {
    text = _(icon .. " " .. GOODREADS.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(GOODREADS.STATUS_NAME[status_id]),
        ok_callback = function()
          self.cache:updateBookStatus(self.ui.document.file, status_id)
          menu_instance.item_table = self:getStatusSubMenuItems()
          menu_instance:updateItems()
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
  }
end

local function goodreadsStatusItems(self)
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, GOODREADS.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, GOODREADS.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, GOODREADS.STATUS.FINISHED),
    self:_statusMenuItem(ICON.PAUSE, GOODREADS.STATUS.PAUSED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, GOODREADS.STATUS.DNF),
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = self.api:removeRead(self.state.book_status.id)
            if result then
              self.state.book_status = {}
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
    },
  }

  local status = self.state.book_status.status_id

  -- Update progress: only when NOT read, DNF, removed, or want to read
  if status and status ~= GOODREADS.STATUS.FINISHED and status ~= GOODREADS.STATUS.DNF and status ~= GOODREADS.STATUS.TO_READ then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.goodreads:getRemotePercent(self.state.book_status) or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

  return items
end

local function fableStatusItem(self, icon, status_id)
  return {
    text = _(icon .. " " .. FABLE.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(FABLE.STATUS_NAME[status_id]),
        ok_callback = function()
          Trapper:wrap(function()
            self.cache:updateBookStatus(self.ui.document.file, status_id)
            menu_instance.item_table = self:getStatusSubMenuItems()
            menu_instance:updateItems()
          end)
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
  }
end

local function fableStatusItems(self)
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, FABLE.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, FABLE.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, FABLE.STATUS.FINISHED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, FABLE.STATUS.DNF),
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            Trapper:wrap(function()
              local result = self.api:removeRead(self.state.book_status.id)
              if result then
                self.state.book_status = {}
                menu_instance.item_table = self:getStatusSubMenuItems()
                menu_instance:updateItems()
              end
            end)
          end
        })
      end,
      keep_menu_open = true,
    },
  }

  local status = self.state.book_status.status_id

  -- Update progress: only when NOT read, DNF, or want to read
  if status and status ~= FABLE.STATUS.FINISHED and status ~= FABLE.STATUS.DNF and status ~= FABLE.STATUS.TO_READ then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.fable:getRemotePercent(self.state.book_status) or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

  return items
end

local function pageboundStatusItem(self, icon, status_id)
  return {
    text = _(icon .. " " .. PAGEBOUND.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(PAGEBOUND.STATUS_NAME[status_id]),
        ok_callback = function()
          self.cache:updateBookStatus(self.ui.document.file, status_id)
          menu_instance.item_table = self:getStatusSubMenuItems()
          menu_instance:updateItems()
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
  }
end

local function pageboundStatusItems(self)
  local items = {
    self:_statusMenuItem(ICON.BOOKMARK, PAGEBOUND.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, PAGEBOUND.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, PAGEBOUND.STATUS.FINISHED),
    self:_statusMenuItem(ICON.PAUSE, PAGEBOUND.STATUS.PAUSED),
    self:_statusMenuItem(ICON.STOP_CIRCLE, PAGEBOUND.STATUS.DNF),
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = self.api:removeRead(self.state.book_status.id)
            if result then
              self.state.book_status = {}
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
    },
  }

  local status = self.state.book_status.status_id

  -- Progress updates are available only during an active reading session.
  if status == PAGEBOUND.STATUS.READING then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress or add forum note: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress or add forum note: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.pagebound:getRemotePercent(self.state.book_status) or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

  return items
end
local status_item_builders = {
  storygraph = storygraphStatusItem,
  hardcover = hardcoverStatusItem,
  goodreads = goodreadsStatusItem,
  fable = fableStatusItem,
  pagebound = pageboundStatusItem,
}

local status_builders = {
  storygraph = storygraphStatusItems,
  hardcover = hardcoverStatusItems,
  goodreads = goodreadsStatusItems,
  fable = fableStatusItems,
  pagebound = pageboundStatusItems,
}

local UpdateStatusMenu = {}
UpdateStatusMenu.__index = UpdateStatusMenu

function UpdateStatusMenu:new(o)
  return setmetatable(o or {}, self)
end

local function providerContext(provider, engine)
  local context = setmetatable({ [provider.key] = engine.provider }, { __index = engine })
  context._statusMenuItem = function(_, icon, status_id)
    return status_item_builders[provider.key](context, icon, status_id)
  end
  context.getStatusSubMenuItems = function()
    return status_builders[provider.key](context)
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
  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    local engine = self.engines[current_provider.key]
    local context = providerContext(current_provider, engine)
    table.insert(menu_items, {
      text = _(current_provider.label),
      enabled_func = function()
        return engine:isActive() and engine.settings:bookLinked()
      end,
      sub_item_table_func = function()
        engine.cache:cacheUserBook()
        return context:getStatusSubMenuItems()
      end,
    })
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
