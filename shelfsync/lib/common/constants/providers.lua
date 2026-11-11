local _ = require("gettext")

local Api = require("shelfsync/lib/storygraph/api")
local HardcoverApi = require("shelfsync/lib/hardcover/api")
local GoodreadsApi = require("shelfsync/lib/goodreads/api")
local FableApi = require("shelfsync/lib/fable/api")
local PageboundApi = require("shelfsync/lib/pagebound/api")
local LibraryThingApi = require("shelfsync/lib/librarything/api")
local StoryGraph = require("shelfsync/lib/storygraph/provider")
local Hardcover = require("shelfsync/lib/hardcover/provider")
local Goodreads = require("shelfsync/lib/goodreads/provider")
local Fable = require("shelfsync/lib/fable/provider")
local Pagebound = require("shelfsync/lib/pagebound/provider")
local LibraryThing = require("shelfsync/lib/librarything/provider")
local StoryGraphSettings = require("shelfsync/lib/storygraph/settings")
local HardcoverSettings = require("shelfsync/lib/hardcover/settings")
local GoodreadsSettings = require("shelfsync/lib/goodreads/settings")
local FableSettings = require("shelfsync/lib/fable/settings")
local PageboundSettings = require("shelfsync/lib/pagebound/settings")
local LibraryThingSettings = require("shelfsync/lib/librarything/settings")
local StoryGraphAccount = require("shelfsync/lib/storygraph/account_ui")
local StoryGraphBookActions = require("shelfsync/lib/storygraph/book_actions")
local HardcoverAccount = require("shelfsync/lib/hardcover/account_ui")
local HardcoverBookActions = require("shelfsync/lib/hardcover/book_actions")
local GoodreadsAccount = require("shelfsync/lib/goodreads/account_ui")
local GoodreadsBookActions = require("shelfsync/lib/goodreads/book_actions")
local FableAccount = require("shelfsync/lib/fable/account_ui")
local FableBookActions = require("shelfsync/lib/fable/book_actions")
local PageboundAccount = require("shelfsync/lib/pagebound/account_ui")
local PageboundBookActions = require("shelfsync/lib/pagebound/book_actions")
local LibraryThingAccount = require("shelfsync/lib/librarything/account_ui")

local STORYGRAPH = require("shelfsync/lib/storygraph/constants")
local HARDCOVER = require("shelfsync/lib/hardcover/constants")
local GOODREADS = require("shelfsync/lib/goodreads/constants")
local FABLE = require("shelfsync/lib/fable/constants")
local PAGEBOUND = require("shelfsync/lib/pagebound/constants")
local LIBRARYTHING = require("shelfsync/lib/librarything/constants")
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
    account_ui = StoryGraphAccount,
    book_actions = StoryGraphBookActions,
    highlight_menu_name = "13_0_make_storygraph_highlight_item",
    auth_setting_key = SETTING.STORYGRAPH.SESSION_COOKIE,
    auth_help_text = _([[Your StoryGraph session has expired. Syncing is paused.

To fix it:
1. Log in to app.thestorygraph.com in a browser
2. Open dev tools (F12) > Application/Storage > Cookies > app.thestorygraph.com
3. Copy '_storygraph_session' and 'remember_user_token' values
4. In KOReader: ShelfSync > Connections > Accounts and sign in > StoryGraph, paste each one in

Re-enable StoryGraph under ShelfSync > Connections > Enabled services.]]),
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
    account_ui = HardcoverAccount,
    book_actions = HardcoverBookActions,
    highlight_menu_name = "13_1_make_hardcover_highlight_item",
    auth_setting_key = SETTING.HARDCOVER.API_TOKEN,
    auth_setting_keys = {
      SETTING.HARDCOVER.ACCESS_TOKEN,
      SETTING.HARDCOVER.REFRESH_TOKEN,
    },
    auth_help_text = _([[Your Hardcover OAuth session or API token is invalid or has expired. Syncing is paused.

To fix it, sign in again from ShelfSync > Connections > Accounts and sign in > Hardcover, or update the API token fallback there.

Re-enable Hardcover under ShelfSync > Connections > Enabled services.]]),
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
    account_ui = GoodreadsAccount,
    book_actions = GoodreadsBookActions,
    highlight_menu_name = "13_2_make_goodreads_highlight_item",
    auth_setting_key = SETTING.GOODREADS.SESSION_COOKIE,
    auth_help_text = _([[Your Goodreads session has expired or is invalid. Syncing is paused.

To fix it:
1. Log in to goodreads.com in a browser
2. Open dev tools (F12) > Network tab, reload the page
3. Click any request to www.goodreads.com, find "Cookie" under Request Headers
4. Right-click it > Copy Value, and paste the whole thing into ShelfSync > Connections > Accounts and sign in > Goodreads

Re-enable Goodreads under ShelfSync > Connections > Enabled services.]]),
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
    account_ui = FableAccount,
    book_actions = FableBookActions,
    highlight_menu_name = "13_3_make_fable_highlight_item",
    auth_setting_key = SETTING.FABLE.REFRESH_TOKEN,
    auth_help_text = _([[Your Fable session has expired or is invalid. Syncing is paused.

To fix it:
Go to ShelfSync > Connections > Accounts and sign in > Fable, and log in again with your Fable email and password.

Re-enable Fable under ShelfSync > Connections > Enabled services.]]),
  },
  {
    key = "pagebound",
    prefix = "Pagebound",
    label = "Pagebound",
    constants = PAGEBOUND,
    api = PageboundApi,
    provider_class = Pagebound,
    settings_class = PageboundSettings,
    settings_filename = "pageboundsync_settings.lua",
    account_ui = PageboundAccount,
    book_actions = PageboundBookActions,
    highlight_menu_name = "13_4_make_pagebound_highlight_item",
    auth_setting_key = SETTING.PAGEBOUND.API_TOKEN,
    auth_help_text = _([[Your Pagebound session has expired or is invalid. Syncing is paused.

To fix it:
Open ShelfSync > Connections > Accounts and sign in > Pagebound and log in again with your Pagebound email and password.

Re-enable Pagebound under ShelfSync > Connections > Enabled services.]]),
  },
  {
    key = "librarything",
    prefix = "LibraryThing",
    label = "LibraryThing",
    constants = LIBRARYTHING,
    api = LibraryThingApi,
    provider_class = LibraryThing,
    settings_class = LibraryThingSettings,
    settings_filename = "librarythingsync_settings.lua",
    account_ui = LibraryThingAccount,
    highlight_menu_name = "13_5_make_librarything_highlight_item",
    auth_setting_key = SETTING.LIBRARYTHING.SESSION_COOKIE,
    auth_help_text = _([[Your LibraryThing session has expired or is invalid. Syncing is paused.

To fix it:
Use ShelfSync > Connections > Accounts and sign in > LibraryThing > Sign in with LibraryThing, or enter its session cookies under LibraryThing > Session cookies (or in shelfsync_config.lua).

Re-enable LibraryThing under ShelfSync > Connections > Enabled services.]]),
  },
}

return PROVIDERS
