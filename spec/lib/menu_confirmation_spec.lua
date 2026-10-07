-- Covers the default for "Confirm changes to book read status": on unless
-- explicitly disabled, for both the menu checkmark and
-- DialogManager:maybeConfirm.

local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager

-- Only needed so the modules below load; none of these specs open them.
package.loaded["ui/widget/spinwidget"] = package.loaded["ui/widget/spinwidget"] or {}
package.loaded["apps/filemanager/filemanagerfilesearcher"] = package.loaded["apps/filemanager/filemanagerfilesearcher"] or {}
package.loaded["shelfsync/lib/common/ui/journal_dialog"] = package.loaded["shelfsync/lib/common/ui/journal_dialog"] or {}
package.loaded["shelfsync/lib/common/ui/search_dialog"] = package.loaded["shelfsync/lib/common/ui/search_dialog"] or {}

local SETTING = require("shelfsync/lib/common/constants/settings")
local CommonMenu = require("shelfsync/lib/common/menu")
local DialogManager = require("shelfsync/lib/common/ui/dialog_manager")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")

local function findItem(items, text)
  for _, item in ipairs(items) do
    if item.text == text then
      return item
    end
  end
end

describe("Status change confirmation default", function()
  local shared

  before_each(function()
    mocks.reset()
    shared = StoryGraphSettings:new("/settings/storygraph.lua", {})
  end)

  it("is on when never changed", function()
    assert.is_true(shared:menuConfirm())
  end)

  it("stays off when explicitly disabled, and on when explicitly enabled", function()
    shared:setMenuConfirm(false)
    assert.is_false(shared:menuConfirm())

    shared:setMenuConfirm(true)
    assert.is_true(shared:menuConfirm())
  end)

  it("shows checked in the menu by default and flips off, then on again", function()
    local item = findItem(CommonMenu:new { settings = shared }:getSubMenuItems(), "Confirm changes to book read status")

    assert.is_true(item.checked_func())

    item.callback()
    assert.are.equal(false, shared:readSetting(SETTING.SHARED.MENU_CONFIRMATION))
    assert.is_false(item.checked_func())

    item.callback()
    assert.are.equal(true, shared:readSetting(SETTING.SHARED.MENU_CONFIRMATION))
    assert.is_true(item.checked_func())
  end)

  describe("DialogManager:maybeConfirm", function()
    local shown, ran, real_show

    before_each(function()
      shown, ran = {}, 0
      real_show = UIManager.show
      UIManager.show = function(_, widget) table.insert(shown, widget) end
    end)

    after_each(function()
      UIManager.show = real_show
    end)

    local function maybeConfirm()
      DialogManager:new { settings = shared }:maybeConfirm({
        text = "Mark book as Read?",
        ok_callback = function() ran = ran + 1 end,
      })
    end

    it("asks before applying the change when never changed", function()
      maybeConfirm()

      assert.are.equal(0, ran)
      assert.are.equal(1, #shown)
      assert.are.equal("Mark book as Read?", shown[1].text)

      shown[1].ok_callback()
      assert.are.equal(1, ran)
    end)

    it("applies the change straight away when explicitly disabled", function()
      shared:setMenuConfirm(false)

      maybeConfirm()

      assert.are.equal(1, ran)
      assert.are.equal(0, #shown)
    end)
  end)
end)
