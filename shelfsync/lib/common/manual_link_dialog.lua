local _ = require("gettext")
local T = require("ffi/util").template

local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local logger = require("shelfsync/lib/common/safe_logger")
local SETTING = require("shelfsync/lib/common/constants/settings")
local SearchDialog = require("shelfsync/lib/common/ui/search_dialog")

local LINK_FIELDS = {
  storygraph = { "book_id", "edition_id", "edition_format", "pages", "title", "link_method" },
  hardcover = { "book_id", "edition_id", "edition_format", "pages", "title", "link_method" },
  goodreads = { "book_id", "edition_id", "pages", "title", "link_method" },
  fable = { "book_id", "pages", "title", "link_method" },
  pagebound = { "book_id", "book_uuid", "pages", "title", "link_method" },
}

local ManualLinkDialog = {}
ManualLinkDialog.__index = ManualLinkDialog

function ManualLinkDialog:new(o)
  return setmetatable(o or {}, self)
end

function ManualLinkDialog:_provider(key)
  for _provider_index, provider in ipairs(self.providers) do
    if provider.key == key then
      return provider
    end
  end
end

function ManualLinkDialog:_activeProvider()
  return self:_provider(self.active_provider_key)
end

function ManualLinkDialog:_activeEngine()
  local provider = self:_activeProvider()
  return provider and self.engines[provider.key]
end

function ManualLinkDialog:_title(provider)
  return T(_("%1: Select book"), _(provider.label))
end

function ManualLinkDialog:_unavailableReason(engine)
  if engine:isWikipediaDocument() then
    return _("Book linking is unavailable for Wikipedia documents.")
  end
  if not engine.settings:providerEnabled() then
    return T(_("%1 is disabled. Enable it in Provider settings to link books."), _(engine.label))
  end
  if not engine.api:hasCredential() then
    return T(_("Sign in to %1 under Accounts to link books."), _(engine.label))
  end
  if not engine.enabled
    and engine.plugin_settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) ~= true then
    return _("Syncing is paused for this provider. Check its account settings or update ShelfSync.")
  end
  return T(_("%1 is unavailable for book linking."), _(engine.label))
end

function ManualLinkDialog:_showSearchError(provider, err)
  if err == "Unauthorized" then
    -- The provider's auth callback already opened its reauthentication help.
    return
  end
  UIManager:show(InfoMessage:new {
    text = T(_("%1 book search failed:\n%2"), _(provider.label), tostring(err)),
    icon = "notice-warning",
  })
end

function ManualLinkDialog:_setItems(provider, engine, title, books, search_value)
  if not self.dialog then
    return
  end
  self.current_items = books or {}
  self.search_value = search_value
  self.dialog:setItems(title, self.current_items, {
    book_id = engine.settings:getLinkedBookId(),
  }, search_value)
end

function ManualLinkDialog:selectProvider(key)
  local provider = self:_provider(key)
  local engine = provider and self.engines[provider.key]
  if not provider or not engine or not self.dialog then
    return
  end

  self.active_provider_key = provider.key
  self.dialog:setActiveTab(provider.key)
  self:_setItems(provider, engine, self:_title(provider), {}, nil)

  if not engine:isActive() then
    self:_setItems(
      provider,
      engine,
      T(_("%1: %2"), _(provider.label), self:_unavailableReason(engine)),
      {},
      nil
    )
    return
  end

  local cached = self.provider_data and self.provider_data[provider.key]
  if cached then
    self:_setItems(provider, engine, cached.title, cached.items, cached.search_value)
    return
  end

  self.load_generation = (self.load_generation or 0) + 1
  local generation = self.load_generation
  Trapper:wrap(function()
    local search_value, books, err = engine.provider:findBookOptions(engine.settings:bookLinked())
    if generation ~= self.load_generation or not self.dialog or self.active_provider_key ~= provider.key then
      return
    end
    if err then
      logger.err(err)
      self.provider_data[provider.key] = nil
      self:_showSearchError(provider, err)
      self:_setItems(provider, engine, self:_title(provider), {}, nil)
      return
    end
    self.provider_data[provider.key] = {
      title = self:_title(provider),
      items = books or {},
      search_value = search_value,
    }
    self:_setItems(provider, engine, self:_title(provider), books, search_value)
  end)
end

function ManualLinkDialog:search(search_value)
  local provider = self:_activeProvider()
  local engine = provider and self.engines[provider.key]
  if not provider or not engine or not self.dialog then
    return true
  end
  if not engine:isActive() then
    UIManager:show(InfoMessage:new {
      text = self:_unavailableReason(engine),
      icon = "notice-warning",
    })
    return true
  end

  local key = provider.key
  local generation = self.load_generation
  Trapper:wrap(function()
    local books, err = engine.api:findBooks(search_value, nil, engine.user:getId())
    if generation ~= self.load_generation or not self.dialog or self.active_provider_key ~= key then
      return
    end
    if err then
      logger.err(err)
      self.provider_data[key] = nil
      self:_showSearchError(provider, err)
      self:_setItems(provider, engine, self:_title(provider), {}, search_value)
      return
    end
    self.provider_data[key] = {
      title = self:_title(provider),
      items = books or {},
      search_value = search_value,
    }
    self:_setItems(provider, engine, self:_title(provider), books, search_value)
  end)
  return true
end

function ManualLinkDialog:linkBook(book)
  local provider = self:_activeProvider()
  local engine = provider and self.engines[provider.key]
  if not provider or not engine or not self.dialog or not engine:isActive() then
    return
  end

  Trapper:wrap(function()
    local linked = engine.provider:linkBookManually(book)
    if linked == false then
      return
    end

    local cached = self.provider_data and self.provider_data[provider.key]
    if not cached then
      cached = { items = {}, search_value = nil }
      self.provider_data[provider.key] = cached
    end
    cached.title = self:_title(provider)
    if self.dialog and self.active_provider_key == provider.key then
      cached.items = self.current_items or cached.items
      cached.search_value = self.search_value
      self:_setItems(provider, engine, cached.title, cached.items, cached.search_value)
      self.dialog:setActiveTab(provider.key)
    end
    if self.on_change then
      self.on_change(provider, book)
    end
  end)
end

function ManualLinkDialog:unlinkActiveProvider()
  local provider = self:_activeProvider()
  local engine = provider and self.engines[provider.key]
  local document = self.ui and self.ui.document
  if not provider or not engine or not document or not engine.settings:bookLinked() then
    return
  end

  engine.settings:updateBookSetting(document.file, {
    _delete = LINK_FIELDS[provider.key],
  })
  if self.provider_data then
    self.provider_data[provider.key] = nil
  end
  if self.on_change then
    self.on_change(provider)
  end
  self:selectProvider(provider.key)
end

function ManualLinkDialog:show(provider_key, callback)
  if not self.ui or not self.ui.document then
    UIManager:show(InfoMessage:new {
      text = _("Unable to link a book: No book is open."),
      icon = "notice-warning",
    })
    return
  end

  if self.dialog then
    self.dialog:onClose()
  end
  self.on_change = callback
  self.current_items = {}
  self.search_value = nil
  self.provider_data = {}

  local initial_provider = provider_key and self:_provider(provider_key)
  if not initial_provider then
    for _provider_index, provider in ipairs(self.providers) do
      local engine = self.engines[provider.key]
      if engine and engine:isActive() then
        initial_provider = provider
        break
      end
    end
  end
  initial_provider = initial_provider or self.providers[1]
  self.active_provider_key = initial_provider.key

  local tabs = {}
  for _provider_index, provider in ipairs(self.providers) do
    local current_provider = provider
    table.insert(tabs, {
      key = current_provider.key,
      text = _(current_provider.label),
      text_func = function()
        local engine = self.engines[current_provider.key]
        local linked = engine and engine.settings:bookLinked()
        return _(current_provider.label) .. (linked and " ✓" or "")
      end,
    })
  end

  local dialog
  dialog = SearchDialog:new {
    title = self:_title(initial_provider),
    items = {},
    active_item = {},
    search_value = nil,
    search_callback = function(search_value)
      return self:search(search_value)
    end,
    select_book_cb = function(book)
      self:linkBook(book)
    end,
    tab_items = tabs,
    active_tab = initial_provider.key,
    tab_callback = function(key)
      self:selectProvider(key)
    end,
    footer_items = {
      {
        text_func = function()
          local provider = self:_activeProvider()
          local engine = self:_activeEngine()
          if engine and engine.settings:bookLinked() then
            return T(_("Hold to unlink: %1"), engine.provider:getLinkedBookLabel())
          end
          return T(_("No saved book link for %1"), provider and _(provider.label) or "")
        end,
        enabled_func = function()
          local engine = self:_activeEngine()
          return engine and engine.settings:bookLinked() or false
        end,
        callback = function() end,
        hold_callback = function()
          self:unlinkActiveProvider()
        end,
      },
    },
    close_callback = function()
      if self.dialog == dialog then
        self.dialog = nil
        self.load_generation = (self.load_generation or 0) + 1
      end
    end,
  }
  self.dialog = dialog
  UIManager:show(dialog)
  self:selectProvider(initial_provider.key)
end

return ManualLinkDialog
