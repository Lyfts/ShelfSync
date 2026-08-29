local _ = require("gettext")

local Api = require("shelfsync/lib/storygraph/api")
local HardcoverApi = require("shelfsync/lib/hardcover/api")
local GoodreadsApi = require("shelfsync/lib/goodreads/api")
local FableApi = require("shelfsync/lib/fable/api")
local StoryGraph = require("shelfsync/lib/storygraph/provider")
local Hardcover = require("shelfsync/lib/hardcover/provider")
local Goodreads = require("shelfsync/lib/goodreads/provider")
local Fable = require("shelfsync/lib/fable/provider")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local FableSettings = require("shelfsync/lib/fable/settings")
local StoryGraphMenu = require("shelfsync/lib/storygraph/menu")
local HardcoverMenu = require("shelfsync/lib/hardcover/menu")
local GoodreadsMenu = require("shelfsync/lib/goodreads/menu")
local FableMenu = require("shelfsync/lib/fable/menu")

local STORYGRAPH = require("shelfsync/lib/storygraph/constants")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local FABLE = require("shelfsync/lib/fable/constants")
local SETTING = require("shelfsync/lib/common/constants/settings")

-- Per-provider wiring for ShelfSyncApp: the classes/constants each engine is
-- built from (see main.lua's ShelfSyncApp:_buildEngine), plus the dispatcher
-- prefix/menu/auth metadata that varies per service.
local PROVIDERS = {
  {
    key = "storygraph",
    prefix = "StoryGraph",
    label = "StoryGraph",
    constants = STORYGRAPH,
    api = Api,
    provider_class = StoryGraph,
    settings_class = StoryGraphSettings,
    settings_filename = "storygraphsync_settings.lua",
    menu_class = StoryGraphMenu,
    highlight_menu_name = "13_0_make_storygraph_highlight_item",
    auth_setting_key = SETTING.STORYGRAPH.SESSION_COOKIE,
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
    constants = HARDCOVER,
    api = HardcoverApi,
    provider_class = Hardcover,
    settings_class = HardcoverSettings,
    settings_filename = "hardcoversync_settings.lua",
    menu_class = HardcoverMenu,
    highlight_menu_name = "13_1_make_hardcover_highlight_item",
    auth_setting_key = SETTING.HARDCOVER.API_TOKEN,
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
    constants = GOODREADS,
    api = GoodreadsApi,
    provider_class = Goodreads,
    settings_class = GoodreadsSettings,
    settings_filename = "goodreadssync_settings.lua",
    menu_class = GoodreadsMenu,
    highlight_menu_name = "13_2_make_goodreads_highlight_item",
    auth_setting_key = SETTING.GOODREADS.SESSION_COOKIE,
    auth_help_text = _([[Your Goodreads session has expired or is invalid. Syncing is paused.

To fix it:
1. Log in to goodreads.com in a browser
2. Open dev tools (F12) > Network tab, reload the page
3. Click any request to www.goodreads.com, find "Cookie" under Request Headers
4. Right-click it > Copy Value, and paste the whole thing into Goodreads menu > Settings > Account (Cookie)

Re-enable syncing afterwards from the Goodreads menu.]]),
  },
  {
    key = "fable",
    prefix = "Fable",
    label = "Fable",
    constants = FABLE,
    api = FableApi,
    provider_class = Fable,
    settings_class = FableSettings,
    settings_filename = "fablesync_settings.lua",
    menu_class = FableMenu,
    highlight_menu_name = "13_3_make_fable_highlight_item",
    auth_setting_key = SETTING.FABLE.REFRESH_TOKEN,
    auth_help_text = _([[Your Fable session has expired or is invalid. Syncing is paused.

To fix it:
Go to Fable menu > Account, and log in again with your Fable email and password.

Re-enable syncing afterwards from the Fable menu.]]),
  },
}

return PROVIDERS
