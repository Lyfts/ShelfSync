-- Regression test for the "Version check frequency" spinner never saving
-- the picked value. KOReader's SpinWidget takes value_min/value_max/
-- title_text (defaulting to 0/20/"") and, on OK, calls `callback(self)`
-- with the widget itself before closing itself. The menu passed
-- min/max/title and read the value from a second callback argument that
-- is never passed, so it saved nil, which deletes the setting and leaves
-- main.lua on its `or 1` day fallback.

local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager

-- Mirrors the parts of KOReader's SpinWidget the menu relies on
-- (frontend/ui/widget/spinwidget.lua): option names and defaults, and that
-- pressing OK stores the picked value, calls `callback(self)`, then closes
-- the widget itself.
local SpinWidget = { value = 1, value_min = 0, value_max = 20, title_text = "" }
SpinWidget.__index = SpinWidget
function SpinWidget:new(o) return setmetatable(o or {}, self) end
function SpinWidget:pressOk(value)
  self.value = value
  if self.callback then self.callback(self) end
  UIManager:close(self)
end
package.loaded["ui/widget/spinwidget"] = SpinWidget

local SETTING = require("shelfsync/lib/common/constants/settings")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")
local CommonMenu = require("shelfsync/lib/common/menu")

describe("CommonMenu version check frequency", function()
  local settings, item, menu_instance, shown, closed

  before_each(function()
    mocks.reset()
    settings = StoryGraphSettings:new("/settings/storygraph.lua", nil)
    local menu = CommonMenu:new { settings = settings, app = {} }
    for _, entry in ipairs(menu:getUpdateSubMenuItems()) do
      if entry.text == "Version check frequency" then item = entry end
    end

    menu_instance = { updated = 0 }
    function menu_instance:updateItems() self.updated = self.updated + 1 end

    shown, closed = nil, 0
    stub(UIManager, "show", function(_, widget) shown = widget end)
    stub(UIManager, "close", function() closed = closed + 1 end)
  end)
  after_each(function() mock.revert(UIManager) end)

  it("opens a 1-30 day picker at the saved interval", function()
    settings:updateSetting(SETTING.VERSION_CHECK_INTERVAL, 5)
    item.callback(menu_instance)

    assert.equals(5, shown.value)
    assert.equals(1, shown.value_min)
    assert.equals(30, shown.value_max)
    assert.equals("Set version check frequency", shown.title_text)
  end)

  it("saves the picked interval and refreshes the menu", function()
    item.callback(menu_instance)
    shown:pressOk(7)

    assert.equals(7, settings:readSetting(SETTING.VERSION_CHECK_INTERVAL))
    assert.equals(1, menu_instance.updated)
    assert.equals(1, closed) -- only SpinWidget's own close, not a second one
    assert.is_true(item.keep_menu_open)
    assert.equals("Check frequency: 7 day(s)", item.text_func())
  end)
end)
