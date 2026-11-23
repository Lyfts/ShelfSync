-- The dashboard's Edit progress button must open before a provider has
-- returned its remote status. A pending lookup is not proof the book stopped
-- being read, and an editor that can't be opened isn't user accessible.
require("spec.support.koreader_mocks")
local UIManager = require("ui/uimanager")

local real_show = UIManager.show
local shown, spin
package.loaded["ui/widget/spinwidget"] = {
  new = function(_, options) spin = options; return options end,
}
local Progress = require("shelfsync/lib/common/ui/shared_progress")

describe("Edit progress eligibility", function()
  local provider, engine, progress

  before_each(function()
    shown, spin = {}, nil
    UIManager.show = function(_, widget) table.insert(shown, widget) end

    provider = {
      key = "hardcover",
      label = "Hardcover",
      constants = {
        STATUS = { READING = "reading" },
        STATUS_NAME = { reading = "Currently Reading", finished = "Read" },
      },
    }
    engine = {
      provider = { tracks_progress = true },
      isActive = function() return true end,
      settings = { bookLinked = function() return true end },
      state = { book_status = {} },
      syncFileUpdates = function() return true end,
    }
    progress = Progress:new {
      ui = {
        document = { file = "/books/test.epub", getPageCount = function() return 200 end },
        getCurrentPage = function() return 10 end,
      },
      providers = { provider },
      engines = { hardcover = engine },
    }
  end)

  after_each(function()
    UIManager.show = real_show
  end)

  it("opens the editor while the remote status is still loading", function()
    progress:show()

    assert.is_table(spin)
    assert.equals(10, spin.value)
    assert.equals(200, spin.value_max)
    assert.equals(spin, shown[1])
  end)

  it("still skips a provider whose known status is not reading", function()
    engine.state.book_status = { status_id = "finished" }

    progress:show()

    assert.is_nil(spin)
    assert.matches("No services can be updated", shown[1].text)
  end)

  it("opens when one provider is still loading and another is not reading", function()
    local finished = {
      key = "fable", label = "Fable",
      constants = provider.constants,
    }
    table.insert(progress.providers, finished)
    progress.engines.fable = {
      provider = { tracks_progress = true },
      isActive = function() return true end,
      settings = { bookLinked = function() return true end },
      state = { book_status = { status_id = "finished" } },
      syncFileUpdates = function() return true end,
    }

    progress:show()

    assert.is_table(spin)
  end)
end)
