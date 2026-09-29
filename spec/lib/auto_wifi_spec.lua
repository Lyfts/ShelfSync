local mocks = require("spec.support.koreader_mocks")
local UIManager, NetworkMgr, Clock = mocks.UIManager, mocks.NetworkMgr, mocks.Clock

local SETTING = require("shelfsync/lib/common/constants/settings")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")

describe("AutoWifi operation lifetime", function()
  before_each(function()
    mocks.reset()
  end)

  it("keeps restored wifi on until a yielding operation has completed", function()
    local settings = {
      readSetting = function(_, key)
        return key == SETTING.SHARED.ENABLE_WIFI
      end,
      debugLog = function() end,
      debugWarn = function() end,
    }
    local wifi = AutoWifi:new { settings = settings, label = "AutoWifi spec" }
    local operation_started = false
    local operation_finished = false

    wifi:withWifi(function()
      operation_started = true
      -- Trapper runs this callback in a coroutine. A yielded network
      -- operation keeps the wifi lease active until it resumes and returns.
      coroutine.yield(5)
      operation_finished = true
    end)

    -- The fake radio associates at t=2. Let the callback start and suspend,
    -- but stop before its simulated request completes at t=7.
    UIManager:_runUntil(3)
    assert.is_true(operation_started)
    assert.is_false(operation_finished)
    assert.is_true(NetworkMgr:isWifiOn())
    assert.is_true(NetworkMgr:isConnected())

    UIManager:_runUntilIdle()

    assert.is_true(operation_finished)
    assert.is_false(NetworkMgr:isWifiOn())
    assert.is_false(NetworkMgr:isConnected())
    assert.is_false(NetworkMgr.wifi_was_on)
  end)
end)
