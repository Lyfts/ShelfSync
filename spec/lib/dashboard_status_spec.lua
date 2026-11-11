local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager
local STATUS = require("shelfsync/lib/common/constants/status").STATUS

local replacements = {
  datastorage = { getDataDir = function() return "/nonexistent-shelfsync-spec" end },
  dispatcher = {},
  ["ui/widget/container/widgetcontainer"] = { extend = function(_, class) return class end },
  ["shelfsync/lib/common/ui/dashboard"] = {},
  ["shelfsync/lib/common/manual_link_dialog"] = {},
  ["shelfsync/lib/common/ui/dialog_manager"] = {},
  ["shelfsync/lib/common/menu"] = {},
  ["shelfsync/lib/common/review_menu"] = {},
  ["shelfsync/lib/common/constants/providers"] = {
    { key = "storygraph", prefix = "StoryGraph" },
    { key = "fable", prefix = "Fable" },
    { key = "librarything", prefix = "LibraryThing" },
  },
}
local saved = {}
for name, value in pairs(replacements) do saved[name], package.loaded[name] = package.loaded[name], value end
local App = assert(loadfile("main.lua"))()
for name in pairs(replacements) do package.loaded[name] = saved[name] end

describe("Dashboard shared status", function()
  local app, sent, messages, original_show
  before_each(function()
    sent, messages = {}, {}
    original_show = UIManager.show
    UIManager.show = function(_, message) table.insert(messages, message.text) end
    app = setmetatable({ ui = { document = { file = "/book.epub" } }, engines = {} }, { __index = App })
    for _, key in ipairs({ "storygraph", "fable", "librarything" }) do
      local name = key
      local engine = {
        label = name,
        settings = { bookLinked = function() return true end,
          readBookSetting = function() return name .. "-id" end },
        dialog_manager = { maybeConfirm = function(_, options) options.ok_callback() end },
        cache = { queueBookStatus = function(_, filename, status, callback)
          table.insert(sent, { name = name, file = filename, status = status })
          callback(name ~= "fable")
        end },
      }
      function engine:isActive() return true end
      app.engines[key] = engine
    end
  end)
  after_each(function() UIManager.show = original_show end)

  it("updates only selected services and reports a failed write", function()
    app:onShelfSyncSetCommonStatus(STATUS.READING, nil, { fable = true })
    assert.same({ { name = "fable", file = "/book.epub", status = STATUS.READING } }, sent)
    assert.matches("could not be updated on fable", messages[1])
  end)

  it("skips unsupported paused statuses and reports them", function()
    app:onShelfSyncSetCommonStatus(STATUS.PAUSED, nil, { storygraph = true, fable = true, librarything = true })
    assert.same({ { name = "storygraph", file = "/book.epub", status = STATUS.PAUSED } }, sent)
    assert.matches("not supported on fable, librarything", messages[1])
  end)

  it("does not change a different book linked while confirmation is open", function()
    local confirm, book_id = nil, "original"
    app.engines.storygraph.settings.readBookSetting = function() return book_id end
    app.engines.storygraph.dialog_manager.maybeConfirm = function(_, options) confirm = options.ok_callback end
    app:onShelfSyncSetCommonStatus(STATUS.READING, nil, { storygraph = true })
    book_id = "replacement"
    confirm()
    assert.same({}, sent)
    assert.matches("could not be updated on storygraph", messages[1])
  end)
end)
