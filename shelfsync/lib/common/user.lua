local SETTING = require("shelfsync/lib/common/constants/settings")

local User = {}
User.__index = User

function User:new(o) return setmetatable(o, self) end

function User:getId()
  local user_id = self.settings:readSetting(SETTING.USER_ID)
  if not user_id then
    local me = self.api:me()
    user_id = me.id
    self.settings:updateSetting(SETTING.USER_ID, user_id)
  end
  return user_id
end

return User
