-- The forum note must be saved at the current reading position: hiding the
-- manual progress editor in the note dialog must not drop the progress write.
require("spec.support.koreader_mocks")

local PageboundApi = require("shelfsync/lib/pagebound/api")

describe("Pagebound forum note progress", function()
  local api, posted, progress

  before_each(function()
    posted, progress = {}, {}
    api = setmetatable({}, { __index = PageboundApi })
    api.findUserBook = function()
      return { id = "status-1", status_id = "reading", total_page_count = 200,
        current_reading_instance = { id = "read-1" } }
    end
    api.updateUserBook = function() error("note must not start a new reading session") end
    api.updateProgress = function(_, book_id, _status, _read, value, update_type, current_page)
      table.insert(progress, { book_id = book_id, value = value,
        update_type = update_type, current_page = current_page })
      return { id = "status-1", status_id = "reading", total_page_count = 200 }
    end
    api.createForumPost = function(_, book_id, title, text)
      table.insert(posted, { book_id = book_id, title = title, text = text })
      return { id = "post-1" }
    end
  end)

  it("pushes the current position before posting the note", function()
    local result = api:createJournalEntry({
      book_id = "book-1", text = "Loved it", note_only = true,
      progress = 42, progress_type = "percentage", progress_percent = 42,
      remote_page = 84, local_page = 42, local_total_pages = 200,
    })

    assert.is_table(result)
    assert.same({ { book_id = "book-1", value = 42, update_type = "percentage",
      current_page = 84 } }, progress)
    assert.equals(1, #posted)
    assert.equals("Loved it", posted[1].text)
    assert.is_not_nil(posted[1].title:find("Thoughts from 42%", 1, true))
  end)

  it("still saves progress when the note text is blank", function()
    local result = api:createJournalEntry({
      book_id = "book-1", text = "  ", note_only = true,
      progress = 42, progress_type = "percentage", progress_percent = 42,
      remote_page = 84,
    })

    assert.is_not_nil(result)
    assert.equals(1, #progress)
    assert.same({}, posted)
  end)
end)
