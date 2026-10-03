local UIManager = require("ui/uimanager")

local Scheduler = {
  retries = {}
}

function Scheduler:clear()
  for fn,_ in pairs(self.retries) do
    UIManager:unschedule(fn)
    self.retries[fn] = nil
  end
end

function Scheduler:withRetries(limit, time_exponent, callback, success_callback, fail_callback)
  time_exponent = time_exponent or 2

  local scheduled_job

  local tries = 0

  local success = function()
    self.retries[callback] = nil
    if success_callback then
      success_callback()
    end
  end

  -- A caller may supply a short delay for a known transient result; failures
  -- without a numeric delay keep the usual exponential backoff.
  local fail = function(retry_delay)
    tries = tries + 1

    if tries < limit then
      local delay = type(retry_delay) == "number" and retry_delay or 2 ^ (time_exponent + tries)
      UIManager:scheduleIn(delay, scheduled_job)
    else
      if fail_callback then
        fail_callback()
      end
    end
  end

  scheduled_job = function()
    callback(success, fail)
  end

  local cancel = function()
    UIManager:unschedule(scheduled_job)
  end

  UIManager:nextTick(scheduled_job)

  return cancel
end

return Scheduler
