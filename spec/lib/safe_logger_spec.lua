local mocks = require("spec.support.koreader_mocks")
local logger = require("shelfsync/lib/common/safe_logger")
local BaseSettings = require("shelfsync/lib/common/base_settings")

describe("safe_logger", function()
  before_each(function()
    mocks.reset()
  end)

  it("redacts search URLs, credential fields, and separately passed body values", function()
    logger.info("GET https://www.goodreads.com/search?q=private%20search%20term")
    logger.warn("csrf=", "csrf-secret")
    logger.info("Goodreads POST Body:", "a private journal note")

    local output = table.concat(mocks.LOG, "\n")
    assert.is_nil(output:find("private", 1, true))
    assert.is_nil(output:find("csrf-secret", 1, true))
    assert.matches("search%?%[REDACTED%]", output)
    assert.matches("csrf= %[REDACTED%]", output)
    assert.matches("POST Body: %[REDACTED%]", output)
  end)

  it("redacts response markup and encoded note fields", function()
    logger.warn("HTML response", '<input name="authenticity_token" value="csrf-secret">')
    logger.info("payload user_status%5Bbody%5D=private%20journal%20note&page=42")
    logger.info("HTTP failure status_code=422 content_type=application/json response_length=128")

    local output = table.concat(mocks.LOG, "\n")
    assert.is_nil(output:find("csrf-secret", 1, true))
    assert.is_nil(output:find("private", 1, true))
    assert.matches("HTML redacted; length=", output)
    assert.matches("user_status%%5Bbody%%5D=%[REDACTED%]", output)
    assert.matches("status_code=422", output)
    assert.matches("content_type=application/json", output)
    assert.matches("response_length=128", output)
  end)

  it("applies redaction through the verbose debug helpers", function()
    local settings = setmetatable({
      verboseLogging = function() return true end,
    }, BaseSettings)

    settings:debugLog("search term=", "private search")
    settings:debugWarn("authenticity_token=", "csrf-secret")

    local output = table.concat(mocks.LOG, "\n")
    assert.is_nil(output:find("private search", 1, true))
    assert.is_nil(output:find("csrf-secret", 1, true))
    assert.matches("search term= %[REDACTED%]", output)
    assert.matches("authenticity_token= %[REDACTED%]", output)
  end)
end)
