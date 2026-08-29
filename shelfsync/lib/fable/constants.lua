local Status = require("shelfsync/lib/common/constants/status")

local Fable = {
  STATUS = Status.STATUS,
  STATUS_NAME = Status.STATUS_NAME,
  CATEGORY = Status.CATEGORY,
  ERROR = Status.ERROR,
  -- Maps STATUS ids to Fable's book_lists `system_type` slugs. This is also
  -- the vocabulary the book-detail endpoint's own per-viewer `status` field
  -- uses (GET /api/books/{id} -> "status": "current_reading", etc), both
  -- confirmed via HAR capture of the Fable Android app. There is no
  -- "paused" system list on Fable (confirmed via the same capture's
  -- GET .../book_lists catalog: only want_to_read/current_reading/finished/
  -- did_not_finish exist), so STATUS.PAUSED is intentionally left unmapped
  -- here and never offered by fable/menu.lua's status submenu.
  SYSTEM_TYPE = {
    [Status.STATUS.TO_READ] = "want_to_read",
    [Status.STATUS.READING] = "current_reading",
    [Status.STATUS.FINISHED] = "finished",
    [Status.STATUS.DNF] = "did_not_finish",
  },
}

return Fable
