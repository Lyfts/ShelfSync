-- Exercise composer callbacks without sending reviews to a live provider.
describe("Review composer", function()
  local saved, composer, shown, cached, submitted
  local function control(id)
    for _, row in ipairs(composer.menu.buttons) do
      for _, item in ipairs(row) do
        if item.id == id then return item end
      end
    end
    error("Missing control: " .. id)
  end

  before_each(function()
    saved, shown, cached, submitted = {}, {}, 0, {}
    local function replace(name, module)
      saved[name] = { package.loaded[name] }
      package.loaded[name] = module
    end
    local widget = { new = function(_, options) return options end }
    replace("logger", { warn = function() end })
    replace("gettext", function(s) return s end)
    replace("device", { screen = {
      getWidth = function() return 600 end,
      getHeight = function() return 800 end,
      scaleBySize = function(_, n) return n end,
    } })
    replace("ffi/blitbuffer", { COLOR_BLACK = 0, COLOR_DARK_GRAY = 1 })
    replace("ui/font", { getFace = function() return {} end })
    replace("ui/widget/textboxwidget", { new = function(_, o)
      o.free = function() end
      return o
    end })
    replace("ui/widget/infomessage", widget)
    replace("ui/widget/spinwidget", widget)
    replace("ui/widget/inputdialog", { new = function(_, o)
      o.getInputText = function(self) return self.input end
      o.onShowKeyboard = function(self) self.keyboard_shown = true end
      return o
    end })
    replace("ui/uimanager", {
      show = function(_, w) shown[#shown + 1] = w end,
      close = function(_, w) w.closed = true end,
      setDirty = function() end,
    })
    replace("ui/widget/buttondialog", { new = function(_, o)
      local controls = {}
      for _, row in ipairs(o.buttons) do
        for _, item in ipairs(row) do
          controls[item.id] = {
            width = 260, enabled = item.enabled ~= false,
            label_widget = { free = function() end },
            label_container = { dimen = { w = 240, h = item.height or 40 } },
            setText = function(self, text) self.text = text end,
            enableDisable = function(self, enabled) self.enabled = enabled end,
          }
        end
      end
      o.getButtonById = function(_, id) return controls[id] end
      o.onClose = function(self)
        self.tap_close_callback()
        self.closed = true
      end
      return o
    end })
    replace("shelfsync/lib/common/review_menu", nil)
    replace("shelfsync/lib/common/constants/providers", {
      { key = "storygraph", label = "StoryGraph" },
      { key = "goodreads", label = "Goodreads" },
      { key = "hardcover", label = "Hardcover" },
      { key = "fable", label = "Fable" },
    })
    local engines = {}
    for _, provider in ipairs(require("shelfsync/lib/common/constants/providers")) do
      engines[provider.key] = {
        settings = {
          providerEnabled = function() return true end,
          bookLinked = function() return true end,
        },
        api = { hasCredential = function() return true end },
        cache = { cacheUserBook = function() cached = cached + 1 end },
        wifi = { withWifi = function(_, callback) callback() end },
        provider = { submitReview = function(_, filename, rating, text)
          submitted[provider.key] = { filename, rating, text }
          return true
        end },
      }
    end
    composer = require("shelfsync/lib/common/review_menu"):new {
      app = { engines = engines, ui = { document = { file = "one.epub" } } },
      settings = { getKoreaderRating = function() return 3 end },
    }
  end)

  after_each(function()
    for name, value in pairs(saved) do package.loaded[name] = value[1] end
  end)

  it("changes ratings in place without repeating cache refreshes", function()
    composer:show()
    local menu = composer.menu
    control("star_4").callback()
    control("less").callback()
    assert.equals(3.75, composer.review.rating)
    assert.equals("3.75 / 5", control("rating").text_func())
    control("star_5").callback()
    assert.is_false(control("more").enabled_func())
    for _ = 1, 20 do control("less").callback() end
    assert.equals(0, composer.review.rating)
    assert.is_false(control("less").enabled_func())
    assert.equals(menu, composer.menu)
    assert.equals(4, cached)
  end)

  it("preserves drafts on close and clears them for another book", function()
    composer:show()
    composer.review.text = "A draft"
    control("close").callback()
    assert.is_nil(composer.menu)
    composer:show()
    assert.equals("A draft", composer.review.text)
    assert.equals(4, cached)
    composer.menu:onClose()
    composer.app.ui.document.file = "two.epub"
    composer:show()
    assert.equals("", composer.review.text)
    assert.equals(8, cached)
  end)

  it("saves multiline text and cancels edits without altering the draft", function()
    composer:show()
    control("text").callback()
    local editor = shown[#shown]
    assert.is_true(editor.allow_newline)
    assert.is_true(editor.keyboard_shown)
    editor.input = "First paragraph\n\n" .. string.rep("読", 110)
    editor.buttons[1][2].callback()
    assert.equals(editor.input, composer.review.text)
    assert.equals("Edit review\nFirst paragraph " .. string.rep("読", 84) .. "…", control("text").text_func())
    control("text").callback()
    local cancelled = shown[#shown]
    cancelled.input = "Discard me"
    cancelled.buttons[1][1].callback()
    assert.equals(editor.input, composer.review.text)
  end)

  it("shows unavailable providers and submits only to selected eligible providers", function()
    composer.app.engines.goodreads.settings.providerEnabled = function() return false end
    composer.app.engines.fable.api.hasCredential = function() return false end
    composer.app.engines.hardcover.settings.bookLinked = function() return false end
    composer:show()
    assert.is_false(control("goodreads").enabled)
    assert.matches("disabled", control("goodreads").text_func())
    assert.matches("not logged in", control("fable").text_func())
    assert.matches("not linked", control("hardcover").text_func())
    control("storygraph").callback()
    assert.is_false(control("submit").enabled_func())
    control("storygraph").callback()
    composer.review.rating = 4.25
    composer.review.text = "Worth reading"
    local menu = composer.menu
    control("submit").callback()
    assert.same({ storygraph = { "one.epub", 4.25, "Worth reading" } }, submitted)
    assert.is_true(menu.closed)
    assert.is_nil(composer.review)
  end)

  it("keeps the composer open when submission fails validation", function()
    composer:show()
    local menu = composer.menu
    for key in pairs(composer.review.selected) do composer.review.selected[key] = false end
    control("submit").callback()
    assert.equals(menu, composer.menu)
    assert.same({}, submitted)
  end)
  it("reports failures and exceptions, retains the draft, and retries only failures", function()
    composer:show()
    composer.review.text = "Keep this review"
    composer.app.engines.goodreads.provider.submitReview = function() return false, "HTTP 404" end
    composer.app.engines.hardcover.provider.submitReview = function() error("offline") end
    composer.app.engines.fable.provider.submitReview = function() return false, "HTTP 500" end
    control("submit").callback()
    assert.equals("Keep this review", composer.review.text)
    assert.is_false(composer.review.selected.storygraph)
    assert.is_true(composer.review.selected.fable)
    assert.matches("Goodreads: HTTP 404", shown[#shown].text)
    assert.matches("Hardcover:", shown[#shown].text)
    assert.matches("Fable: HTTP 500", shown[#shown].text)
  end)

end)
