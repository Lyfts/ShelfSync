local _ = require("gettext")
local math = require("math")

local T = require("ffi/util").template

local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")

local STORYGRAPH = require("shelfsync/lib/storygraph/constants")
local ICON = require("shelfsync/lib/common/constants/icons")

local BookActions = {}

function BookActions.items(self)
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
        return BookActions.reviewItems(self, menu_instance)
      end,
      keep_menu_open = true,
      separator = true
    })
  end

  return items
end

function BookActions.reviewItems(self, menu_instance)
  if not self.state.review then
    local existing_review = nil
    if self.state.book_status.review_url then
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

return BookActions
