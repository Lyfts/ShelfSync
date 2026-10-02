local _ = require("gettext")
local math = require("math")
local os = require("os")
local T = require("ffi/util").template
local Device = require("device")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local QRMessage = require("ui/widget/qrmessage")
local Trapper = require("ui/trapper")

local OAuthClient = require("shelfsync/lib/hardcover/oauth_client")

local DeviceAuthDialog = {}
DeviceAuthDialog.__index = DeviceAuthDialog

function DeviceAuthDialog:new()
  return setmetatable({}, self)
end

function DeviceAuthDialog:show(on_success, on_error)
  self.on_success = on_success
  self.on_error = on_error
  Trapper:wrap(function()
    self:_run()
  end)
end

function DeviceAuthDialog:_run()
  local device_auth, err = OAuthClient:requestDeviceCode()
  if not device_auth then
    if err ~= "cancelled" and self.on_error then
      self.on_error(err or _("Could not start sign-in"))
    end
    return
  end

  self.interval = math.max(1, tonumber(device_auth.interval) or 5)
  local expires_at = os.time() + (tonumber(device_auth.expires_in) or 600)
  self.cancelled = false
  self:_buildDialog(device_auth)
  UIManager:show(self.dialog)

  while not self.cancelled and os.time() < expires_at do
    local response, poll_error = OAuthClient:pollToken(
      device_auth.device_code,
      self.interval,
      self.dialog
    )

    if poll_error == "cancelled" then
      self.cancelled = true
      break
    elseif response and response.access_token then
      self:_close()
      if self.on_success then
        self.on_success(response)
      end
      return
    elseif response and response.error == "authorization_pending" then
      -- The user has not approved the device yet.
    elseif response and response.error == "slow_down" then
      self.interval = self.interval + 5
    elseif response and response.error == "access_denied" then
      self:_close()
      if self.on_error then
        self.on_error(_("Hardcover sign-in was denied"))
      end
      return
    elseif response and (response.error == "expired_token" or response.error == "expired_device_code") then
      break
    elseif response and response.error then
      self:_close()
      if self.on_error then
        self.on_error(response.error_description or response.error)
      end
      return
    else
      -- A short network interruption should not invalidate the user's code.
      self.interval = math.min(self.interval + 5, 30)
    end
  end

  self:_close()
  if not self.cancelled and self.on_error then
    self.on_error(_("Hardcover sign-in code expired"))
  end
end

function DeviceAuthDialog:_buildDialog(device_auth)
  local verification_uri = device_auth.verification_uri or "https://hardcover.app/link"
  local qr_uri = device_auth.verification_uri_complete or verification_uri
  self.dialog = ButtonDialog:new {
    title = T(
      _("Go to:\n%1\n\nand enter this code:\n\n%2\n\nWaiting for approval…"),
      verification_uri,
      device_auth.user_code or ""
    ),
    dismissable = false,
    buttons = {
      {
        {
          text = _("Show QR code"),
          callback = function()
            self.qr_widget = QRMessage:new {
              text = qr_uri,
              width = Device.screen:getWidth(),
              height = Device.screen:getHeight(),
              dismiss_callback = function()
                self.qr_widget = nil
              end,
            }
            UIManager:show(self.qr_widget)
          end,
        },
      },
      {
        {
          text = _("Cancel"),
          callback = function()
            self.cancelled = true
            if self.dialog and self.dialog.dismiss_callback then
              self.dialog.dismiss_callback()
            end
          end,
        },
      },
    },
  }
end

function DeviceAuthDialog:_close()
  if self.qr_widget then
    UIManager:close(self.qr_widget)
    self.qr_widget = nil
  end
  if self.dialog then
    UIManager:close(self.dialog)
    self.dialog = nil
  end
end

return DeviceAuthDialog
