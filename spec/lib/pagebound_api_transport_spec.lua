require("spec.support.koreader_mocks")

local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")

local transport_error = "host or service not provided, or not known"
local decode = setmetatable({ simple = {} }, {
  __call = function() return nil end,
})

package.loaded["socket.http"] = {
  request = function() return nil, transport_error end,
}
package.loaded["ltn12"] = {
  source = { string = function() return function() end end },
}
package.loaded["json"] = {
  encode = function() return "{}" end,
  decode = decode,
  util = { null = {} },
}
package.loaded["socketutil"] = {
  set_timeout = function() end,
  reset_timeout = function() end,
  table_sink = function() return function() end end,
}
Trapper.dismissableRunInSubprocess = function(_, fn)
  return true, fn()
end

local PageboundApi = require("shelfsync/lib/pagebound/api")
local SETTING = require("shelfsync/lib/common/constants/settings")

describe("PageboundApi network transport failures", function()
  before_each(function()
    NetworkMgr._connected = true
    NetworkMgr._online = true
  end)

  it("returns the transport error when an authenticated request cannot connect", function()
    local values = {
      [SETTING.PAGEBOUND.API_TOKEN] = "api-token",
      [SETTING.PAGEBOUND.FIREBASE_ID_TOKEN] = "firebase-token",
      [SETTING.PAGEBOUND.REFRESH_TOKEN] = "refresh-token",
      [SETTING.PAGEBOUND.TOKEN_EXPIRES_AT] = os.time() + 3600,
    }
    PageboundApi.settings = {
      readSetting = function(_, key) return values[key] end,
      updateSetting = function(_, key, value) values[key] = value end,
      debugWarn = function() end,
    }

    local code, err = PageboundApi:request("/api/v1/books", "GET")

    assert.is_nil(code)
    assert.are.equal(transport_error, err)
  end)

  it("does not report a Firebase transport failure as an authentication failure", function()
    local values = {
      [SETTING.PAGEBOUND.EMAIL] = "reader@example.test",
      [SETTING.PAGEBOUND.PASSWORD_PLAIN] = "password",
    }
    local notified = false
    PageboundApi.settings = {
      readSetting = function(_, key) return values[key] end,
      updateSetting = function(_, key, value) values[key] = value end,
      debugWarn = function() end,
    }
    PageboundApi.on_error = function() notified = true end

    local code, err = PageboundApi:request("/api/v1/books", "GET")

    assert.is_nil(code)
    assert.is_truthy(err and err:find(transport_error, 1, true))
    assert.is_false(notified)
  end)
end)
