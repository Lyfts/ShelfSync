-- The Reading status menu must separate "all services", an explicit subset
-- action and individual services, instead of mixing statuses and a vague
-- "Choose services" button in one dialog.
require("spec.support.koreader_mocks")

local menus, set_calls = {}, {}
local Menu = { updateItems = function() end }
function Menu:new(o) table.insert(menus, o); return o end
package.loaded["ui/widget/menu"] = Menu
package.loaded["ui/widget/spinwidget"] = { new = function(_, o) return o end }
package.loaded["ui/widget/buttondialog"] = { new = function(_, o) return o end }
package.loaded["shelfsync/lib/common/constants/providers"] = {
  { key = "one", label = "One" },
  { key = "two", label = "Two" },
}

local STATUS = require("shelfsync/lib/common/constants/status")
local Dashboard = require("shelfsync/lib/common/ui/dashboard")

local function findItem(items, text)
  for _, item in ipairs(items) do
    if item.text == text then return item end
  end
end

describe("Dashboard Reading status picker", function()
  local dashboard

  before_each(function()
    menus, set_calls = {}, {}
    local engines = {}
    for _, key in ipairs({ "one", "two" }) do
      local engine = {
        label = key,
        state = { book_status = { status_id = STATUS.STATUS.READING } },
        settings = { bookLinked = function() return true end },
      }
      function engine:isActive() return true end
      engines[key] = engine
    end
    local app = {
      engines = engines,
      ui = { document = { file = "/book.epub" } },
      onShelfSyncSetCommonStatus = function(_, status_id, done, selected)
        table.insert(set_calls, { status = status_id, selected = selected })
        for key, engine in pairs(engines) do
          if selected == nil or selected[key] then
            engine.state.book_status.status_id = status_id
          end
        end
        if done then done() end
      end,
    }
    dashboard = Dashboard:new { app = app }
  end)

  it("labels the group actions and each individual service", function()
    dashboard:_showStatusPicker()

    local items = menus[1].item_table
    assert.equals("Reading status", menus[1].title)
    assert.is_table(findItem(items, "All linked services"))
    assert.is_table(findItem(items, "Some linked services…"))
    assert.is_false(findItem(items, "── Individual services ──").enabled)
    assert.is_table(findItem(items, "One — Currently Reading"))
    assert.is_table(findItem(items, "Two — Currently Reading"))
  end)

  it("sets one service's status from its own submenu", function()
    dashboard:_showStatusPicker()
    local item = findItem(menus[1].item_table, "One — Currently Reading")
    local statuses = item.sub_item_table_func(menus[1])

    findItem(statuses, "Read").callback()

    assert.equals(1, #set_calls)
    assert.equals(STATUS.STATUS.FINISHED, set_calls[1].status)
    assert.same({ one = true }, set_calls[1].selected)
    assert.is_table(findItem(menus[1].item_table, "One — Read"))
  end)

  it("sets all linked services at once", function()
    dashboard:_showStatusPicker()
    local statuses = findItem(menus[1].item_table, "All linked services").sub_item_table_func(menus[1])

    findItem(statuses, "Want To Read").callback()

    assert.equals(1, #set_calls)
    assert.is_nil(set_calls[1].selected)
  end)

  it("applies a subset status to the checked services", function()
    dashboard:_showStatusPicker()
    local sub = findItem(menus[1].item_table, "Some linked services…").sub_item_table_func(menus[1])
    local one = findItem(sub, "One")
    assert.is_true(one.checked_func())
    one.callback()
    assert.is_false(one.checked_func())

    local statuses = findItem(sub, "Set status on checked services").sub_item_table_func()
    findItem(statuses, "Read").callback()

    assert.equals(1, #set_calls)
    assert.is_false(set_calls[1].selected.one)
    assert.is_true(set_calls[1].selected.two)
  end)
end)
