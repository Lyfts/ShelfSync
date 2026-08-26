local _ = require("gettext")
local DataStorage = require("datastorage")

-- Migration: merge the legacy storygraph_config.lua / hardcover_config.lua
-- files into a single shelfsync_config.lua. Very old installs (pre-Hardcover
-- support) stored StoryGraph's session cookie in hardcover_config.lua under
-- the same field names storygraph_config.lua uses now, so that file's
-- content is treated as StoryGraph's rather than Hardcover's in that case.
local plugin_dir = DataStorage:getDataDir() .. "/plugins/shelfsync.koplugin"
local new_config = plugin_dir .. "/shelfsync_config.lua"

local function loadLegacyConfig(path)
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local ok, result = pcall(dofile, path)
    if ok and type(result) == "table" then return result end
    return nil
end

if not io.open(new_config, "r") then
    local storygraph_path = plugin_dir .. "/storygraph_config.lua"
    local hardcover_path = plugin_dir .. "/hardcover_config.lua"

    local storygraph_legacy = loadLegacyConfig(storygraph_path)
    local hardcover_legacy = loadLegacyConfig(hardcover_path)

    if not storygraph_legacy and hardcover_legacy and hardcover_legacy.session_cookie ~= nil then
        storygraph_legacy, hardcover_legacy = hardcover_legacy, nil
    end

    if storygraph_legacy or hardcover_legacy then
        local f_out = io.open(new_config, "w")
        if f_out then
            f_out:write("return {\n")
            f_out:write(("  storygraph = {\n    session_cookie = %q,\n    remember_user_token = %q,\n  },\n"):format(
                (storygraph_legacy and storygraph_legacy.session_cookie) or '',
                (storygraph_legacy and storygraph_legacy.remember_user_token) or ''
            ))
            f_out:write(("  hardcover = {\n    token = %q,\n  },\n"):format(
                (hardcover_legacy and hardcover_legacy.token) or ''
            ))
            f_out:write("}\n")
            f_out:close()

            os.remove(storygraph_path)
            os.remove(hardcover_path)
        end
    end
end

local Dispatcher = require("dispatcher")
local math = require("math")

local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Api = require("shelfsync/lib/storygraph/api")
local HardcoverApi = require("shelfsync/lib/hardcover/api")
local GoodreadsApi = require("shelfsync/lib/goodreads/api")
local AutoWifi = require("shelfsync/lib/common/auto_wifi")
local Cache = require("shelfsync/lib/common/cache")
local StoryGraph = require("shelfsync/lib/storygraph/business")
local Hardcover = require("shelfsync/lib/hardcover/business")
local Goodreads = require("shelfsync/lib/goodreads/business")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local PageMapper = require("shelfsync/lib/common/page_mapper")
local SyncEngine = require("shelfsync/lib/common/sync_engine")
local User = require("shelfsync/lib/common/user")

local DialogManager = require("shelfsync/lib/common/ui/dialog_manager")
local StoryGraphMenu = require("shelfsync/lib/storygraph/menu")
local HardcoverMenu = require("shelfsync/lib/hardcover/menu")
local GoodreadsMenu = require("shelfsync/lib/goodreads/menu")
local CommonMenu = require("shelfsync/lib/common/menu")

local STORYGRAPH = require("shelfsync/lib/storygraph/constants")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local SETTING = require("shelfsync/lib/common/constants/settings")

local MANDATORY_UPDATE_MESSAGE = _("A mandatory update is required due to StoryGraph/Goodreads API changes. Please update the plugin to continue.")

-- Per-provider dispatcher actions. Each becomes a KOReader dispatcher action
-- named "<key>_<snake>" broadcasting event "<Prefix><suffix>", which in turn
-- is wired below to `self.engines[key]:on<suffix>(...)`.
local ACTIONS = {
  { suffix = "Link", snake = "link", title = "Link book" },
  { suffix = "Track", snake = "track", title = "Track progress" },
  { suffix = "StopTrack", snake = "stop_track", title = "Stop tracking progress" },
  { suffix = "UpdateProgress", snake = "update_progress", title = "Update progress" },
}

-- Broadcast-only events (not exposed as dispatcher actions) that also get a
-- delegating `on<Prefix><suffix>` handler routed to the matching engine.
local BROADCAST_HANDLERS = { "Note", "PullPosition" }

local PROVIDERS = {
  {
    key = "storygraph",
    prefix = "StoryGraph",
    label = "StoryGraph",
    business_field = "storygraph",
    constants = STORYGRAPH,
    api = Api,
    business_class = StoryGraph,
    settings_class = StoryGraphSettings,
    settings_filename = "storygraphsync_settings.lua",
    menu_class = StoryGraphMenu,
    highlight_menu_name = "13_0_make_storygraph_highlight_item",
    auth_setting_key = SETTING.SESSION_COOKIE,
    auth_help_text = _([[Your StoryGraph session has expired. Syncing is paused.

To fix it:
1. Log in to app.thestorygraph.com in a browser
2. Open dev tools (F12) > Application/Storage > Cookies > app.thestorygraph.com
3. Copy '_storygraph_session' and 'remember_user_token' values
4. In KOReader: StoryGraph menu > Settings > Account (Cookies & Tokens), paste each one in

Re-enable syncing afterwards from the StoryGraph menu.]]),
  },
  {
    key = "hardcover",
    prefix = "Hardcover",
    label = "Hardcover",
    business_field = "hardcover",
    constants = HARDCOVER,
    api = HardcoverApi,
    business_class = Hardcover,
    settings_class = HardcoverSettings,
    settings_filename = "hardcoversync_settings.lua",
    menu_class = HardcoverMenu,
    highlight_menu_name = "13_1_make_hardcover_highlight_item",
    auth_setting_key = SETTING.API_TOKEN,
    auth_help_text = _([[Your Hardcover API token is invalid or has expired. Syncing is paused.

To fix it:
1. Go to hardcover.app/account/api in a browser
2. Copy your API token
3. In KOReader: Hardcover menu > Settings > Account (API Token), paste it in

Re-enable syncing afterwards from the Hardcover menu.]]),
  },
  {
    key = "goodreads",
    prefix = "Goodreads",
    label = "Goodreads",
    business_field = "goodreads",
    constants = GOODREADS,
    api = GoodreadsApi,
    business_class = Goodreads,
    settings_class = GoodreadsSettings,
    settings_filename = "goodreadssync_settings.lua",
    menu_class = GoodreadsMenu,
    highlight_menu_name = "13_2_make_goodreads_highlight_item",
    auth_setting_key = SETTING.SESSION_COOKIE,
    auth_help_text = _([[Your Goodreads session has expired or is invalid. Syncing is paused.

To fix it:
1. Log in to goodreads.com in a browser
2. Open dev tools (F12) > Network tab, reload the page
3. Click any request to www.goodreads.com, find "Cookie" under Request Headers
4. Right-click it > Copy Value, and paste the whole thing into Goodreads menu > Settings > Account (Cookie)

Re-enable syncing afterwards from the Goodreads menu.]]),
  },
}

local ShelfSyncApp = WidgetContainer:extend {
  name = "shelfsync",
  is_doc_only = false,
  state = nil,
  engines = nil,
  width = nil,
  enabled = true
}

function ShelfSyncApp:onDispatcherRegisterActions()
  for _prov_idx, provider in ipairs(PROVIDERS) do
    for _action_idx, action in ipairs(ACTIONS) do
      Dispatcher:registerAction(provider.key .. "_" .. action.snake, {
        category = "none",
        event = provider.prefix .. action.suffix,
        title = _(provider.label .. ": " .. action.title),
        general = true,
      })
    end
  end
end

-- Delegate every dispatcher action and broadcast-only event to the matching
-- engine, e.g. ShelfSyncApp:onStoryGraphLink() -> self.engines.storygraph:onLink(),
-- ShelfSyncApp:onHardcoverNote(params) -> self.engines.hardcover:onNote(params).
for _, provider in ipairs(PROVIDERS) do
  local suffixes = {}
  for _, action in ipairs(ACTIONS) do
    table.insert(suffixes, action.suffix)
  end
  for _, suffix in ipairs(BROADCAST_HANDLERS) do
    table.insert(suffixes, suffix)
  end

  for _, suffix in ipairs(suffixes) do
    ShelfSyncApp["on" .. provider.prefix .. suffix] = function(self, ...)
      local engine = self.engines[provider.key]
      return engine["on" .. suffix](engine, ...)
    end
  end
end

-- Builds the full per-provider object graph (settings/user/cache/page_mapper/
-- wifi/dialog_manager/business/menu) and wraps it in a SyncEngine. `settings`
-- and `plugin_settings` are constructed by the caller so the StoryGraph and
-- Hardcover engines can be pointed at the same plugin-wide settings instance
-- (see ShelfSyncApp:init).
function ShelfSyncApp:_buildEngine(provider, settings, plugin_settings)
  local state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
  }

  local user = User:new { api = provider.api, settings = settings }
  local cache = Cache:new { api = provider.api, user = user, settings = settings, state = state, ui = self.ui }
  local page_mapper = PageMapper:new { state = state, ui = self.ui }
  local wifi = AutoWifi:new { settings = settings, label = provider.label }
  local dialog_manager = DialogManager:new {
    api = provider.api,
    user = user,
    label = provider.label,
    page_mapper = page_mapper,
    settings = settings,
    state = state,
    ui = self.ui,
    wifi = wifi,
  }
  local business = provider.business_class:new {
    api = provider.api,
    user = user,
    cache = cache,
    dialog_manager = dialog_manager,
    settings = settings,
    state = state,
    ui = self.ui,
    wifi = wifi,
  }

  local engine = SyncEngine:new {
    label = provider.label,
    constants = provider.constants,
    highlight_menu_name = provider.highlight_menu_name,
    auth_setting_key = provider.auth_setting_key,
    api = provider.api,
    user = user,
    cache = cache,
    page_mapper = page_mapper,
    wifi = wifi,
    dialog_manager = dialog_manager,
    business = business,
    settings = settings,
    plugin_settings = plugin_settings,
    ui = self.ui,
    view = self.view,
    state = state,
  }

  local menu = provider.menu_class:new {
    app = self,
    enabled = true,
    api = provider.api,
    user = user,
    cache = cache,
    dialog_manager = dialog_manager,
    [provider.business_field] = business,
    page_mapper = page_mapper,
    settings = settings,
    plugin_settings = plugin_settings,
    state = state,
    ui = self.ui,
  }
  engine.menu = menu

  settings:subscribe(function(field, change, original_value)
    engine:onSettingsChanged(field, change, original_value)
  end)

  -- Settings shared across providers (see base_settings.lua's SHARED_KEYS)
  -- are notified on `plugin_settings`, not on this engine's own `settings`
  -- instance, so subscribe to that too when they're not already the same
  -- object (true for the StoryGraph engine, whose settings IS plugin_settings).
  if settings ~= plugin_settings then
    plugin_settings:subscribe(function(field, change, original_value)
      engine:onSettingsChanged(field, change, original_value)
    end)
  end

  provider.api.settings = settings
  provider.api.on_error = function(err)
    if not err or not engine.enabled then
      return
    end

    if err == "Unauthorized" or (err.message and string.find(err.message, "login")) then
      engine:disable()
      UIManager:show(InfoMessage:new {
        text = provider.auth_help_text,
        icon = "notice-warning",
      })
    end
  end

  engine:initializePageUpdate()

  return engine
end

function ShelfSyncApp:init()
  self.state = {}
  self.engines = {}

  -- StoryGraph's settings double as the plugin-wide settings: version-check
  -- bookkeeping and the "ignore mandatory update" override apply to the
  -- whole plugin (both providers), not one provider at a time, so they only
  -- live in one place rather than being duplicated per engine.
  local storygraph_provider = PROVIDERS[1]
  local plugin_settings = storygraph_provider.settings_class:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), storygraph_provider.settings_filename),
    self.ui
  )
  self.storygraph_settings = plugin_settings

  for _, provider in ipairs(PROVIDERS) do
    local settings = (provider == storygraph_provider) and plugin_settings
      or provider.settings_class:new(
        ("%s/%s"):format(DataStorage:getSettingsDir(), provider.settings_filename),
        self.ui,
        plugin_settings
      )
    self.engines[provider.key] = self:_buildEngine(provider, settings, plugin_settings)
  end

  self.common_menu = CommonMenu:new { settings = plugin_settings, app = self }

  self:onDispatcherRegisterActions()
  self.ui.menu:registerToMainMenu(self)
end

function ShelfSyncApp:startReadCache()
  for _, engine in pairs(self.engines) do
    engine:startReadCache()
  end
end

function ShelfSyncApp:cancelPendingUpdates()
  for _, engine in pairs(self.engines) do
    engine:cancelPendingUpdates()
  end
end

function ShelfSyncApp:initiateVersionCheck()
  if self.state.version_checked then return end

  local last_check = self.storygraph_settings:readSetting(SETTING.LAST_VERSION_CHECK) or 0
  local interval = self.storygraph_settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
  local now = os.time()

  -- Always check on first startup of the session, otherwise respect interval
  if not self.state.session_checked or (now - last_check >= (interval * 24 * 3600)) then
    self.state.session_checked = true
    self:checkForUpdates()
  else
    -- Schedule it for when it's next due
    local next_check_in = math.max(1, (interval * 24 * 3600) - (now - last_check))
    UIManager:scheduleIn(next_check_in, self.checkForUpdates, self)
  end
end

function ShelfSyncApp:checkForUpdates()
  -- If we're already out of date and NOT ignoring, no need to keep checking
  if not self.enabled and not self.storygraph_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) then
    return
  end

  self.engines.storygraph.wifi:withWifi(function()
    local Github = require("shelfsync/lib/common/github")
    local info = Github:fetchVersionInfo()
    if not info then return end

    self.state.version_checked = true
    self.storygraph_settings:updateSetting(SETTING.LAST_VERSION_CHECK, os.time())

    -- Check for mandatory update
    local plugin_path = self.path or (DataStorage:getPluginDir() .. "/shelfsync.koplugin")
    local Meta = dofile(plugin_path .. "/_meta.lua")

    if info.api_version and Meta.api_version < info.api_version then
      -- Always mark as disabled internally if version is outdated
      self.enabled = false
      for _, engine in pairs(self.engines) do
        engine:disable()
      end

      if self.storygraph_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) then
        UIManager:show(Notification:new {
          text = _("StoryGraph: Mandatory update available (Ignored)"),
          timeout = 5
        })
      else
        self:cancelPendingUpdates()

        if self.storygraph_settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false then
          UIManager:show(Notification:new {
            text = MANDATORY_UPDATE_MESSAGE,
            timeout = 10
          })
        end
        return
      end
    else
      -- Up to date, schedule the next check
      local interval = self.storygraph_settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
      UIManager:scheduleIn(interval * 24 * 3600, self.checkForUpdates, self)
    end
  end)
end

function ShelfSyncApp:onReaderReady()
  for _, engine in pairs(self.engines) do
    engine:onReaderReady()
  end
  UIManager:scheduleIn(1, self.initiateVersionCheck, self)
end

function ShelfSyncApp:onPosUpdate(pos, page)
  for _, engine in pairs(self.engines) do
    engine:onPosUpdate(pos, page)
  end
end

function ShelfSyncApp:onPageUpdate(page)
  for _, engine in pairs(self.engines) do
    engine:onPageUpdate(page)
  end
end

function ShelfSyncApp:onUpdatePos()
  for _, engine in pairs(self.engines) do
    engine:onUpdatePos()
  end
end

function ShelfSyncApp:onDocumentClose()
  for _, engine in pairs(self.engines) do
    engine:onDocumentClose()
  end
end

function ShelfSyncApp:onSuspend()
  for _, engine in pairs(self.engines) do
    engine:onSuspend()
  end
end

function ShelfSyncApp:onResume()
  for _, engine in pairs(self.engines) do
    engine:onResume()
  end
end

function ShelfSyncApp:onNetworkDisconnecting()
  for _, engine in pairs(self.engines) do
    engine:onNetworkDisconnecting()
  end
end

function ShelfSyncApp:onNetworkConnected()
  for _, engine in pairs(self.engines) do
    engine:onNetworkConnected()
  end
end

function ShelfSyncApp:onEndOfBook()
  for _, engine in pairs(self.engines) do
    engine:onEndOfBook()
  end
end

function ShelfSyncApp:onDocSettingsItemsChanged(file, doc_settings)
  for _, engine in pairs(self.engines) do
    engine:onDocSettingsItemsChanged(file, doc_settings)
  end
end

function ShelfSyncApp:addToMainMenu(menu_items)
  local sub_items = {}
  for _, provider in ipairs(PROVIDERS) do
    table.insert(sub_items, self.engines[provider.key].menu:mainMenu())
  end

  table.insert(sub_items, {
    text = _("Common settings"),
    sub_item_table_func = function()
      return self.common_menu:getSubMenuItems()
    end,
  })

  table.insert(sub_items, {
    text = _("About"),
    keep_menu_open = true,
    callback = function()
      local Font = require("ui/font")
      local Github = require("shelfsync/lib/common/github")
      local VERSION = require("shelfsync_version")

      local info = Github:fetchVersionInfo()
      local version = table.concat(VERSION, ".")
      local new_release_str = ""
      if info and info.plugin_version and Github:isNewer(info.plugin_version) then
        new_release_str = " (latest v" .. info.plugin_version .. ")"
      end

      UIManager:show(InfoMessage:new {
        text = [[
ShelfSync plugin
v]] .. version .. new_release_str .. [[


Synchronizes reading progress, notes, and status to The StoryGraph, Hardcover, and/or Goodreads.

See the StoryGraph, Hardcover, and Goodreads submenus for service-specific settings.

Project:
github.com/Lyfts/ShelfSync]],
        face = Font:getFace("cfont", 18),
        show_icon = false,
      })
    end,
  })

  menu_items.shelfsync = {
    text = _("ShelfSync"),
    sorting_hint = "more_tools",
    sub_item_table = sub_items,
  }
end

return ShelfSyncApp
