local Status = require("shelfsync/lib/common/constants/status")

local Hardcover = {
  STATUS = Status.STATUS,
  STATUS_NAME = Status.STATUS_NAME,
  CATEGORY = Status.CATEGORY,
  ERROR = Status.ERROR,
  PRIVACY = {
    PUBLIC = 1,
    FOLLOWS = 2,
    PRIVATE = 3,
  },
}

return Hardcover
