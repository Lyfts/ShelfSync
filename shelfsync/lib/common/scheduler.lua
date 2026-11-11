local UIManager = require("ui/uimanager")

local Scheduler = {}

-- Runs `callback(success, fail, is_cancelled)` until it calls success(), or
-- fail() has been called `limit` times. Returns a function that cancels the
-- chain: it unschedules the next try, and makes success() and fail() do
-- nothing from then on, so a try that's already running (e.g. waiting for
-- Wi-Fi or a request) can't schedule another one or run either callback.
-- Such a try can check is_cancelled() before doing more work.
function Scheduler:withRetries(limit, time_exponent, callback, success_callback, fail_callback)
  time_exponent = time_exponent or 2

  local scheduled_job

  local tries = 0
  local cancelled = false

  local is_cancelled = function()
    return cancelled
  end

  local success = function()
    if cancelled then
      return
    end
    if success_callback then
      success_callback()
    end
  end

  -- A caller may supply a short delay for a known transient result; failures
  -- without a numeric delay keep the usual exponential backoff.
  local fail = function(retry_delay)
    if cancelled then
      return
    end
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
    callback(success, fail, is_cancelled)
  end

  local cancel = function()
    cancelled = true
    UIManager:unschedule(scheduled_job)
  end

  UIManager:nextTick(scheduled_job)

  return cancel
end

return Scheduler
