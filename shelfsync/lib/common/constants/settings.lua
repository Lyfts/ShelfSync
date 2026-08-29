local Settings = {
  ALWAYS_SYNC = "always_sync",
  BOOKS = "books",
  ENABLE_WIFI = "enable_wifi",
  LINK_BY_ISBN = "link_by_isbn",
  LINK_BY_TITLE = "link_by_title",
  MENU_CONFIRMATION = "menu_confirmation",
  SYNC = "sync",
  TRACK_FREQUENCY = "track_frequency",
  TRACK_METHOD = "track_method",
  TRACK_PERCENTAGE = "track_percentage",
  TRACK = {
    FREQUENCY = "frequency",
    PROGRESS = "progress",
    PAGES = "pages",
  },
  USER_ID = "user_id",
  INCLUDE_LOCATION_IN_NOTES = "include_location_in_notes",
  IGNORE_VERSION_BLOCK = "ignore_version_block",
  SHOW_VERSION_DIALOG = "show_version_dialog",
  VERSION_CHECK_INTERVAL = "version_check_interval",
  LAST_VERSION_CHECK = "last_version_check",
  SYNC_BY_REMOTE_PAGES = "sync_by_remote_pages",
  TRACK_PAGE_STEP = "track_page_step",
  SYNC_ON_OPEN = "sync_on_open",
  VERBOSE_LOGGING = "verbose_logging",
  PROVIDER_ENABLED = "provider_enabled",
}

Settings.AUTOLINK_OPTIONS = { Settings.LINK_BY_ISBN, Settings.LINK_BY_TITLE }

-- Settings that are combined across all providers instead of being kept
-- independently per service (see shelfsync/lib/common/menu.lua, which is the
-- only place these are surfaced in the UI). See base_settings.lua's
-- readSetting/updateSetting, which transparently redirect any instance other
-- than `shared` itself to `shared` for these keys.
Settings.SHARED_KEYS = {
  [Settings.ENABLE_WIFI] = true,
  [Settings.MENU_CONFIRMATION] = true,
  [Settings.INCLUDE_LOCATION_IN_NOTES] = true,
  [Settings.VERBOSE_LOGGING] = true,
  [Settings.SYNC_BY_REMOTE_PAGES] = true,
  [Settings.ALWAYS_SYNC] = true,
  [Settings.SYNC_ON_OPEN] = true,
  [Settings.TRACK_METHOD] = true,
  [Settings.TRACK_FREQUENCY] = true,
  [Settings.TRACK_PERCENTAGE] = true,
  [Settings.TRACK_PAGE_STEP] = true,
  [Settings.LINK_BY_ISBN] = true,
  [Settings.LINK_BY_TITLE] = true,
}

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
