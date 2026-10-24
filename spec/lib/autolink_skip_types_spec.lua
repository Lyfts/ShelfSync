-- File types set to never be linked automatically (e.g. cbz for manga) are
-- skipped by every autolink method, but can still be linked by hand.

local mocks = require("spec.support.koreader_mocks")

local SETTING = require("shelfsync/lib/common/constants/settings")
local BaseProvider = require("shelfsync/lib/common/base_provider")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")

describe("Autolink file types", function()
  local settings, provider, lookups, file

  before_each(function()
    mocks.reset()
    file = "/books/One Piece 01.cbz"
    local ui = {
      document = {
        file = file,
        getProps = function() return { title = "One Piece 1", authors = "Eiichiro Oda", identifiers = "isbn:9781569319017" } end,
      },
      doc_settings = mocks.makeStore(),
    }
    settings = HardcoverSettings:new("/settings/hardcover.lua", ui, nil)
    lookups = 0
    provider = BaseProvider:new {
      label = "Hardcover",
      ui = ui,
      settings = settings,
      user = { getId = function() return 1 end },
      wifi = { withWifi = function(_, fn) fn(true) end },
      api = {
        findBookByIdentifiers = function() lookups = lookups + 1 end,
        findBooks = function() lookups = lookups + 1; return {} end,
      },
    }
  end)

  it("parses what's typed into a list of extensions", function()
    settings:setAutolinkSkipTypes(" .CBZ, cbr  cb7,cbz ")
    assert.same({ "cbz", "cbr", "cb7" }, settings:autolinkSkipTypes())
    assert.same({ "cbz", "cbr", "cb7" }, settings:readSetting(SETTING.SHARED.AUTOLINK_SKIP_TYPES))
    settings:setAutolinkSkipTypes("")
    assert.same({}, settings:autolinkSkipTypes())
  end)

  it("matches a file's extension, whatever its case", function()
    settings:setAutolinkSkipTypes("cbz")
    assert.is_true(settings:autolinkSkipsFile("/books/One Piece 01.CBZ"))
    assert.is_false(settings:autolinkSkipsFile("/books/novel.epub"))
    assert.is_false(settings:autolinkSkipsFile("/books.cbz/novel"))
    assert.is_false(settings:autolinkSkipsFile(nil))
  end)

  it("doesn't look a skipped file type up at all", function()
    settings:setAutolinkSkipTypes("cbz, cbr")
    local done = false
    provider:tryAutolink(function() done = true end)
    assert.is_true(done)
    assert.equals(0, lookups)
  end)

  it("still links every other file type", function()
    settings:setAutolinkSkipTypes("cbr")
    provider:tryAutolink()
    assert.is_true(lookups > 0)
  end)
end)
