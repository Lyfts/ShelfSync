-- The Edit progress picker must show each linked provider's current progress,
-- edit one provider on its own, enter a percentage as well as pages, and still
-- offer a single all-at-once update.
require("spec.support.koreader_mocks")
local UIManager = require("ui/uimanager")

package.loaded["ffi/util"].template = function(s, ...)
  local args = { ... }
  local index = 0
  return (s:gsub("%%%d", function()
    index = index + 1
    return tostring(args[index])
  end))
end

local real_show = UIManager.show
local spin, dialog, confirm_text, updated, sent, messages
package.loaded["ui/widget/spinwidget"] = {
  new = function(_, options) spin = options; return options end,
}
package.loaded["ui/widget/buttondialog"] = {
  new = function(_, options)
    dialog = options
    options.onClose = function() end
    return options
  end,
}
local Progress = require("shelfsync/lib/common/ui/shared_progress")

local CONSTANTS = {
  STATUS = { READING = "reading", FINISHED = "finished" },
  STATUS_NAME = { reading = "Currently Reading", finished = "Read" },
}

local function makeEngine(percent, status_id)
  local engine = {
    provider = {
      tracks_progress = true,
      getRemotePercent = function(_, status) return status.percent end,
      getRemoteProgress = function() return 0 end,
    },
    state = { book_status = { status_id = status_id, percent = percent } },
    settings = { bookLinked = function() return true end, debugWarn = function() end },
    dialog_manager = { maybeConfirm = function(_, options)
      confirm_text = options.text
      options.ok_callback()
    end },
  }
  function engine:isActive() return true end
  function engine:syncFileUpdates() return true end
  function engine:getProgressTarget(local_page, _total_pages) return local_page * 2, "pages", 400 end
  function engine:updateProgressValue(callback, value, update_type)
    table.insert(updated, self)
    table.insert(sent, { value = value, update_type = update_type })
    callback(true)
  end
  return engine
end

describe("Edit progress per provider", function()
  local progress, engines

  before_each(function()
    spin, dialog, confirm_text, updated, sent, messages = nil, nil, nil, {}, {}, {}
    UIManager.show = function(_, widget)
      if widget and widget.text then table.insert(messages, widget.text) end
    end
    engines = {
      one = makeEngine(42.4, "reading"),
      two = makeEngine(80, "reading"),
    }
    progress = Progress:new {
      ui = {
        document = { file = "/book.epub", getPageCount = function() return 200 end },
        getCurrentPage = function() return 10 end,
      },
      providers = {
        { key = "one", label = "One", constants = CONSTANTS },
        { key = "two", label = "Two", constants = CONSTANTS },
      },
      engines = engines,
    }
  end)

  after_each(function() UIManager.show = real_show end)

  local function findButton(text)
    for _, row in ipairs(dialog.buttons) do
      for _, button in ipairs(row) do
        if button.text and button.text:find(text, 1, true) then return button end
      end
    end
  end

  it("shows each provider's remote progress and disables ineligible ones", function()
    engines.two.state.book_status.status_id = "finished"

    progress:show()

    assert.equals("One: 42%", findButton("One:").text)
    assert.is_true(findButton("One:").enabled)
    assert.matches("Two: not currently reading", findButton("Two:").text)
    assert.is_false(findButton("Two:").enabled)
  end)

  it("updates only the chosen provider", function()
    progress:show()
    findButton("One:").callback()

    assert.is_table(spin)
    spin.value = 50
    spin.callback(spin)

    assert.same({ engines.one }, updated)
    assert.same({ { value = 100, update_type = "pages" } }, sent)
    assert.matches("One: Page 100 / 400", confirm_text)
  end)

  it("still updates every eligible provider at once by page", function()
    progress:show()
    findButton("Set all linked services at once").callback()

    spin.value = 50
    spin.callback(spin)

    assert.same({ engines.one, engines.two }, updated)
  end)

  it("enters a percentage for all providers directly", function()
    progress:show()
    findButton("Enter percentage").callback()

    assert.matches("Percentage", dialog.title)
    findButton("Set all linked services at once").callback()
    assert.equals(100, spin.value_max)
    assert.equals("Set progress percentage", spin.title_text)
    assert.equals(5, spin.value)

    spin.value = 75
    spin.callback(spin)

    assert.same({ engines.one, engines.two }, updated)
    assert.same({ { value = 75, update_type = "percentage" },
      { value = 75, update_type = "percentage" } }, sent)
    assert.is_not_nil(confirm_text:find("Set progress to 75%", 1, true))
  end)

  it("skips providers that cannot send percentages at all", function()
    engines.two.provider.canPushProgress = function() return false end

    progress:show()
    findButton("Enter percentage").callback()
    findButton("Set all linked services at once").callback()
    spin.value = 75
    spin.callback(spin)

    assert.same({ engines.one }, updated)
    assert.matches("Left unchanged: Two", messages[#messages])
  end)
end)
