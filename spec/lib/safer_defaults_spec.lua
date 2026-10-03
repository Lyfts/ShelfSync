-- Covers the defaults for settings a user may never have touched:
--   1. "Automatically link by title and author" is off unless explicitly
--      enabled, while identifier and ISBN linking stay on unless explicitly
--      disabled. The menu, BaseSettings:autolinkEnabled() and
--      BaseProvider:tryAutolink() must all agree on that.
--   2. "Confirm changes to book read status" is on unless explicitly
--      disabled, for both the menu checkmark and DialogManager:maybeConfirm.

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
local HardcoverProvider = require("shelfsync/lib/hardcover/provider")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")

local function findItem(items, text)
  for _, item in ipairs(items) do
    if item.text == text then
      return item
    end
  end
end

describe("Auto-link defaults", function()
  local ui, shared, settings

  before_each(function()
    mocks.reset()

    ui = {
      document = {
        file = "/books/test.epub",
        getProps = function()
          return { title = "Test Book", authors = "Test Author" }
        end,
      },
      doc_settings = mocks.makeStore(),
    }

    -- Mirrors main.lua: the auto-link keys are SHARED_KEYS stored on the
    -- StoryGraph settings, and every other provider reads them through it.
    shared = StoryGraphSettings:new("/settings/storygraph.lua", ui)
    settings = HardcoverSettings:new("/settings/hardcover.lua", ui, shared)
  end)

  describe("when never changed", function()
    it("enables identifier and ISBN linking but not title and author", function()
      assert.is_true(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_IDENTIFIER))
      assert.is_true(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_ISBN))
      assert.is_false(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_TITLE))
      assert.is_true(settings:autolinkEnabled())
    end)
  end)

  describe("when explicitly set", function()
    it("keeps title and author linking on when explicitly enabled", function()
      shared:updateSetting(SETTING.SHARED.LINK_BY_TITLE, true)

      assert.is_true(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_TITLE))
    end)

    it("turns identifier and ISBN linking off when explicitly disabled", function()
      shared:updateSetting(SETTING.SHARED.LINK_BY_IDENTIFIER, false)
      shared:updateSetting(SETTING.SHARED.LINK_BY_ISBN, false)

      assert.is_false(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_IDENTIFIER))
      assert.is_false(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_ISBN))
    end)

    it("reports auto-link as disabled when identifier and ISBN are off and title was never enabled", function()
      shared:updateSetting(SETTING.SHARED.LINK_BY_IDENTIFIER, false)
      shared:updateSetting(SETTING.SHARED.LINK_BY_ISBN, false)

      assert.is_false(settings:autolinkEnabled())

      shared:updateSetting(SETTING.SHARED.LINK_BY_TITLE, true)

      assert.is_true(settings:autolinkEnabled())
    end)
  end)

  describe("menu", function()
    local items

    before_each(function()
      items = CommonMenu:new { settings = shared }:getAutoLinkSubMenuItems()
    end)

    it("shows identifier and ISBN checked and title and author unchecked by default", function()
      assert.is_true(findItem(items, "Automatically link by provider identifier").checked_func())
      assert.is_true(findItem(items, "Automatically link by ISBN").checked_func())
      assert.is_false(findItem(items, "Automatically link by title and author").checked_func())
    end)

    it("flips title and author linking on, then off again", function()
      local item = findItem(items, "Automatically link by title and author")

      item.callback()
      assert.are.equal(true, shared:readSetting(SETTING.SHARED.LINK_BY_TITLE))
      assert.is_true(item.checked_func())
      assert.is_true(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_TITLE))

      item.callback()
      assert.are.equal(false, shared:readSetting(SETTING.SHARED.LINK_BY_TITLE))
      assert.is_false(item.checked_func())
      assert.is_false(settings:autolinkMethodEnabled(SETTING.SHARED.LINK_BY_TITLE))
    end)

    it("flips identifier linking off from its default", function()
      local item = findItem(items, "Automatically link by provider identifier")

      item.callback()
      assert.are.equal(false, shared:readSetting(SETTING.SHARED.LINK_BY_IDENTIFIER))
      assert.is_false(item.checked_func())
    end)
  end)

  describe("tryAutolink on a document with only a title", function()
    local calls, provider_instance

    before_each(function()
      calls = { findBooks = 0 }
      provider_instance = HardcoverProvider:new {
        label = "Hardcover",
        api = {
          findBooks = function()
            calls.findBooks = calls.findBooks + 1
            return {}
          end,
        },
        user = { getId = function() return 1 end },
        settings = settings,
        state = { book_status = {} },
        ui = ui,
        wifi = { withWifi = function(_, callback) callback(true) end },
      }
    end)

    it("does not search by title when title and author linking was never enabled", function()
      local done = false
      provider_instance:tryAutolink(function() done = true end)
      UIManager:_runUntilIdle()

      assert.is_true(done)
      assert.are.equal(0, calls.findBooks)
    end)

    it("searches by title once title and author linking is enabled", function()
      shared:updateSetting(SETTING.SHARED.LINK_BY_TITLE, true)

      provider_instance:tryAutolink()
      UIManager:_runUntilIdle()

      assert.are.equal(1, calls.findBooks)
    end)
  end)
end)

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
