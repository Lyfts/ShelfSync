local Settings = {
  BOOKS = "books",
  SYNC = "sync",
  TRACK = {
    FREQUENCY = "frequency",
    PROGRESS = "progress",
    PAGES = "pages",
  },
  USER_ID = "user_id",
  IGNORE_VERSION_BLOCK = "ignore_version_block",
  SHOW_VERSION_DIALOG = "show_version_dialog",
  VERSION_CHECK_INTERVAL = "version_check_interval",
  LAST_VERSION_CHECK = "last_version_check",
  PROVIDER_ENABLED = "provider_enabled",
}

-- Settings that are combined across all providers instead of being kept
-- independently per service (see shelfsync/lib/common/menu.lua, which is the
-- only place these are surfaced in the UI). See base_settings.lua's
-- readSetting/updateSetting, which transparently redirect any instance other
-- than `shared` itself to `shared` for these keys.
Settings.SHARED = {
  ENABLE_WIFI = "enable_wifi",
  MENU_CONFIRMATION = "menu_confirmation",
  INCLUDE_LOCATION_IN_NOTES = "include_location_in_notes",
  VERBOSE_LOGGING = "verbose_logging",
  SYNC_BY_REMOTE_PAGES = "sync_by_remote_pages",
  ALWAYS_SYNC = "always_sync",
  SYNC_ON_OPEN = "sync_on_open",
  TRACK_METHOD = "track_method",
  TRACK_FREQUENCY = "track_frequency",
  TRACK_PERCENTAGE = "track_percentage",
  TRACK_PAGE_STEP = "track_page_step",
  LINK_BY_IDENTIFIER = "link_by_identifier",
  LINK_BY_ISBN = "link_by_isbn",
  LINK_BY_TITLE = "link_by_title",
}

-- Order here doubles as the priority BaseProvider:_runAutolink tries each
-- method in: provider identifier first (most specific), then ISBN, then
-- title+author (least specific, most prone to false matches).
Settings.AUTOLINK_OPTIONS = { Settings.SHARED.LINK_BY_IDENTIFIER, Settings.SHARED.LINK_BY_ISBN, Settings.SHARED.LINK_BY_TITLE }

-- Lookup set derived from Settings.SHARED, used by base_settings.lua to test
-- membership in O(1) without listing every key twice.
Settings.SHARED_KEYS = {}
for _, key in pairs(Settings.SHARED) do
  Settings.SHARED_KEYS[key] = true
end

-- Provider-specific keys: only ever read/written through that provider's own
-- settings instance, so they're kept out of the flat top-level namespace
-- above. SESSION_COOKIE is intentionally duplicated between STORYGRAPH and
-- GOODREADS -- same key string, but each stored in that provider's own
-- settings file, so there's no collision.
Settings.STORYGRAPH = {
  SESSION_COOKIE = "session_cookie",
  REMEMBER_TOKEN = "remember_token",
}

Settings.GOODREADS = {
  SESSION_COOKIE = "session_cookie",
  COOKIE_REFRESH_URL = "cookie_refresh_url",
  COOKIE_REFRESH_TOKEN = "cookie_refresh_token",
}

Settings.HARDCOVER = {
  API_TOKEN = "api_token",
}

Settings.FABLE = {
  EMAIL = "email",
  ID_TOKEN = "id_token",
  REFRESH_TOKEN = "refresh_token",
  TOKEN_EXPIRES_AT = "token_expires_at",
}

return Settings
