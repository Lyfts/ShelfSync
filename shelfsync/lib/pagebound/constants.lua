local Status = require("shelfsync/lib/common/constants/status")

local Pagebound = {
  STATUS = Status.STATUS,
  STATUS_NAME = {
    [Status.STATUS.TO_READ] = "Interested",
    [Status.STATUS.READING] = "Currently Reading",
    [Status.STATUS.FINISHED] = "Finished",
    [Status.STATUS.PAUSED] = "Paused",
    [Status.STATUS.DNF] = "Did Not Finish",
  },
  CATEGORY = Status.CATEGORY,
  ERROR = Status.ERROR,
  SYSTEM_STATUS = {
    [Status.STATUS.TO_READ] = "interested",
    [Status.STATUS.READING] = "current",
    [Status.STATUS.FINISHED] = "finished",
    [Status.STATUS.PAUSED] = "paused",
    [Status.STATUS.DNF] = "dnf",
  },
  FIREBASE_API_KEY = "AIzaSyDCfBJ51pRZgHueBfBz0KNDiPNev1ClnGg",
  TYPESENSE_API_KEY = "SgSrp2Vx4V4wjJAwnME6uWUufNdi9BxM",
  API_URL = "https://prod-pagebound-api.onrender.com",
  TYPESENSE_URL = "https://hztadco4ku1vqi6lp.a1.typesense.net",
}

Pagebound.STATUS_BY_SYSTEM_STATUS = {}
for status_id, system_status in pairs(Pagebound.SYSTEM_STATUS) do
  Pagebound.STATUS_BY_SYSTEM_STATUS[system_status] = status_id
end

return Pagebound
