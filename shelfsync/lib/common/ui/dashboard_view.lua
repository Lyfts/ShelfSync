local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Screen = Device.screen
local View = FocusManager:extend {}

function View:init()
  local width, height = Screen:getWidth(), Screen:getHeight()
  local pad = Screen:scaleBySize(16)
  local title = TitleBar:new {
    width = width,
    title = _("ShelfSync"),
    with_bottom_line = true,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }
  local card_width = width - 2 * pad
  local cover
  if self.document and self.document.getCoverPageImage then
    local ok, image = pcall(self.document.getCoverPageImage, self.document)
    if ok then cover = image end
  end
  local cover_width = cover and math.min(Screen:scaleBySize(105), math.floor(card_width / 4)) or 0
  local gap = cover and pad or 0
  local text_width = card_width - 2 * pad - cover_width - gap
  local book = HorizontalGroup:new { align = "top" }
  if cover then
    table.insert(book, ImageWidget:new {
      image = cover, width = cover_width, height = Screen:scaleBySize(145), scale_factor = 0,
    })
    table.insert(book, HorizontalSpan:new { width = gap })
  end
  local book_text = VerticalGroup:new {
    align = "left",
    TextBoxWidget:new {
      text = self.book_title, width = text_width, face = Font:getFace("smalltfont"), bold = true,
    },
    VerticalSpan:new { width = Screen:scaleBySize(5) },
    TextBoxWidget:new {
      text = self.book_details, width = text_width, face = Font:getFace("smallinfofont"),
    },
  }
  if self.progress then
    table.insert(book_text, VerticalSpan:new { width = Screen:scaleBySize(8) })
    table.insert(book_text, ProgressWidget:new {
      width = text_width, height = Screen:scaleBySize(8), percentage = self.progress,
    })
  end
  table.insert(book, book_text)
  local card = FrameContainer:new {
    width = card_width,
    padding = pad,
    bordersize = Screen:scaleBySize(1),
    radius = Screen:scaleBySize(6),
    book,
  }
  for _index, row in ipairs(self.buttons) do
    for _button_index, button in ipairs(row) do
      button.height = Screen:scaleBySize(52)
      button.font_size = 19
      button.font_bold = false
    end
  end
  self.buttons[1][1].background = Blitbuffer.COLOR_LIGHT_GRAY
  self.buttons[1][1].font_bold = true
  local reading = ButtonTable:new {
    width = card_width,
    buttons = { self.buttons[1], self.buttons[2], self.buttons[3] },
    show_parent = self,
  }
  local management = ButtonTable:new {
    width = card_width,
    buttons = { self.buttons[4], self.buttons[5] },
    show_parent = self,
  }
  self.layout = {}
  self:mergeLayoutInVertical(reading)
  self:mergeLayoutInVertical(management)
  local function section(label)
    local text = TextWidget:new { text = label, face = Font:getFace("smallinfofontbold", 18) }
    return LeftContainer:new { dimen = Geom:new { w = card_width, h = text:getSize().h }, text }
  end
  local content = VerticalGroup:new {
    align = "center",
    VerticalSpan:new { width = pad },
    card,
    VerticalSpan:new { width = pad },
    section(_("READING")),
    VerticalSpan:new { width = Screen:scaleBySize(5) },
    reading,
    VerticalSpan:new { width = pad },
    section(_("MANAGE")),
    VerticalSpan:new { width = Screen:scaleBySize(5) },
    management,
    VerticalSpan:new { width = pad },
  }
  local available = height - title:getSize().h
  local content_height = content:getSize().h
  local content_width = width
  if content_height > available then
    content_width = width - ScrollableContainer:getScrollbarWidth()
  end
  local body = ScrollableContainer:new {
    dimen = Geom:new { w = width, h = available },
    show_parent = self,
    CenterContainer:new { dimen = Geom:new { w = content_width, h = content_height }, content },
  }
  self.scroll_body = body
  self[1] = FrameContainer:new {
    dimen = Geom:new { w = width, h = height },
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    VerticalGroup:new { title, body },
  }
  self.key_events.Close = { { "Back" } }
end

function View:onFocusMove(args)
  local result = FocusManager.onFocusMove(self, args)
  local body, focus = self.scroll_body, self:getFocusItem()
  if body and body._is_scrollable and focus and focus.dimen then
    local top, bottom = body.dimen.y, body.dimen.y + body.dimen.h
    if focus.dimen.y < top then
      body:_scrollBy(0, focus.dimen.y - top)
    elseif focus.dimen.y + focus.dimen.h > bottom then
      body:_scrollBy(0, focus.dimen.y + focus.dimen.h - bottom)
    end
  end
  return result
end

function View:onScreenResize()
  self:free()
  self:init()
  UIManager:setDirty(self, "full")
  return false
end

function View:onShow()
  UIManager:setDirty(self, "ui")
end

function View:onClose()
  UIManager:close(self)
  UIManager:setDirty(nil, "ui")
  if self.close_callback then self.close_callback() end
  return true
end

return View
