local Status = require("shelfsync/lib/common/constants/status")

return {
  STATUS = Status.STATUS,
  STATUS_NAME = Status.STATUS_NAME,
  CATEGORY = Status.CATEGORY,
  ERROR = Status.ERROR,
  -- Goodreads accepts Paused and Did Not Finish shelf writes, but its current
  -- book-page parser only reads the three canonical exclusive shelves.
  WRITE_ONLY_STATUS_IDS = {
    [Status.STATUS.PAUSED] = true,
    [Status.STATUS.DNF] = true,
  },
}
