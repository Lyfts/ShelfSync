require("spec.support.koreader_mocks")

local replacements = {
  ["ffi/blitbuffer"] = {},
  ["ui/widget/titlebar"] = {},
  ["ui/widget/container/centercontainer"] = {},
  ["ui/widget/container/framecontainer"] = {},
  device = { screen = {} },
  ["ui/geometry"] = {},
  ["ui/gesturerange"] = {},
  ["ui/widget/container/inputcontainer"] = { extend = function(_, class) return class end },
  ["ui/widget/inputdialog"] = {},
  ["ui/widget/buttontable"] = {},
  ["shelfsync/lib/common/ui/search_menu"] = {},
  ["ui/size"] = { border = { window = 1 } },
  ["ui/widget/verticalgroup"] = {},
}
local saved = {}
for name, value in pairs(replacements) do saved[name], package.loaded[name] = package.loaded[name], value end
local old_dialog = package.loaded["shelfsync/lib/common/ui/search_dialog"]
package.loaded["shelfsync/lib/common/ui/search_dialog"] = nil
local SearchDialog = require("shelfsync/lib/common/ui/search_dialog")
package.loaded["shelfsync/lib/common/ui/search_dialog"] = old_dialog
for name in pairs(replacements) do package.loaded[name] = saved[name] end

describe("Book search results", function()
  it("preserves the selected edition and provider metadata", function()
    local book = { book_id = "work", edition_id = "edition", book_uuid = "uuid",
      title = "Example", contributions = {}, pages = 321 }
    local entry = SearchDialog.createListItem({}, book, {})
    assert.equals(book, entry.source_book)
    assert.equals("edition", entry.source_book.edition_id)
    assert.equals("uuid", entry.source_book.book_uuid)
    assert.equals(321, entry.source_book.pages)
  end)

  it("renders a guidance row without a book identifier", function()
    local entry = SearchDialog.createListItem({}, { title = "Sign in first", contributions = {}, unavailable = true }, {})
    assert.equals("book-unavailable", entry.file)
    assert.is_true(entry.source_book.unavailable)
  end)
end)
