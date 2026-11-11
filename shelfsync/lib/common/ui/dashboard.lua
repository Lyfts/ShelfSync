local _ = require("gettext")
local Device = require("device")
local math = require("math")

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local PROVIDERS = require("shelfsync/lib/common/constants/providers")
local STATUS = require("shelfsync/lib/common/constants/status")
local DashboardMenus = require("shelfsync/lib/common/ui/dashboard_menus")
local SharedProgress = require("shelfsync/lib/common/ui/shared_progress")

local Screen = Device.screen
local Dashboard = {}
Dashboard.__index = Dashboard

function Dashboard:new(o)
  return setmetatable(o or {}, self)
end

function Dashboard:_linkedEngines()
  local linked = {}
  for _index, provider in ipairs(PROVIDERS) do
    local engine = self.app.engines[provider.key]
    if self.app.ui.document and engine.settings:bookLinked() then
      table.insert(linked, engine)
    end
  end
  return linked
end

function Dashboard:_closeHome()
  local dialog = self.home_dialog
  self.home_dialog = nil
  if dialog then
    dialog:onClose()
  end
end

function Dashboard:show()
  self:_closeHome()
  local document = self.app.ui.document
  local title, details = _("No book open"), _("Open a book to manage its reading and sync.")
  local progress
  if document then
    local props = document:getProps() or {}
    title = props.title and props.title ~= "" and props.title or _("Current book")
    local author = type(props.authors) == "string" and props.authors or props.author
    local page = self.app.ui.getCurrentPage and self.app.ui:getCurrentPage()
    local total = document:getPageCount()
    local lines = {}
    if type(author) == "string" and author ~= "" then table.insert(lines, author) end
    if page and total and total > 0 then
      progress = math.max(0, math.min(1, page / total))
      table.insert(lines, _("Page ") .. tostring(page) .. _(" of ") .. tostring(total)
        .. "  ·  " .. tostring(math.floor(page * 100 / total + 0.5)) .. "%")
    end
    local linked = self:_linkedEngines()
    local names, status, mixed, unknown, tracking = {}, nil, false, false, 0
    for _index, engine in ipairs(linked) do
      table.insert(names, engine.label)
      if engine.settings:syncEnabled() then tracking = tracking + 1 end
      local current = engine.state.book_status and engine.state.book_status.status_id
      if current then
        if status and status ~= current then mixed = true end
        status = current
      else
        unknown = true
      end
    end
    table.insert(lines, #names > 0 and (_("Linked: ") .. table.concat(names, ", "))
      or _("No services linked yet"))
    if #names > 0 then
      local state = mixed and _("Mixed statuses") or (unknown and _("Some statuses unknown"))
        or (status and STATUS.STATUS_NAME[status] and _(STATUS.STATUS_NAME[status]))
      if state then table.insert(lines, _("Last known: ") .. state) end
      table.insert(lines, _("Automatic tracking: ") .. tracking .. "/" .. #names)
    end
    details = table.concat(lines, "\n")
  end

  local View = require("shelfsync/lib/common/ui/dashboard_view")
  local dialog
  dialog = View:new {
    document = document,
    progress = progress,
    book_title = title,
    book_details = details,
    buttons = {
      { { text = _("Sync now"), enabled = document ~= nil,
          callback = function() self:_syncNow() end },
        { text = _("Edit progress"), enabled = document ~= nil,
          callback = function()
            SharedProgress:new { ui = self.app.ui, providers = PROVIDERS, engines = self.app.engines }:show()
          end } },
      { { text = _("Reading status"), enabled = document ~= nil,
          callback = function() self:_showStatusPicker() end },
        { text = _("Link or relink"), enabled = document ~= nil,
          callback = function() self:_showLinkPicker() end } },
      { { text = _("Write a review"), enabled = document ~= nil,
          callback = function() self.app.review_menu:show() end },
        { text = _("Automatic tracking"), enabled = document ~= nil,
          callback = function() self:_showTrackingMenu() end } },
      { { text = _("Book options"), enabled = document ~= nil,
          callback = function() self:_showBookOptions() end },
        { text = _("Connections"), callback = function() self:_showProvidersMenu() end } },
      { { text = _("Settings"), callback = function() self:_showSettingsMenu() end },
        { text = _("About"), callback = function() self:_showAbout() end } },
    },
    close_callback = function()
      if self.home_dialog == dialog then self.home_dialog = nil end
    end,
  }
  self.home_dialog = dialog
  UIManager:show(dialog)
end

function Dashboard:_syncNow()
  local linked = self:_linkedEngines()
  for _index, engine in ipairs(linked) do
    if engine:isActive() and engine.provider.tracks_progress ~= false then
      self.app:onShelfSyncUpdateAllProgress()
      return
    end
  end
  UIManager:show(InfoMessage:new {
    text = #linked == 0 and _("Link this book to a service first.")
      or _("No active linked service can sync reading progress."),
    icon = "notice-warning",
  })
end

function Dashboard:_showStatusPicker()
  local selected = {}
  local count = 0
  for _index, provider in ipairs(PROVIDERS) do
    local engine = self.app.engines[provider.key]
    selected[provider.key] = engine:isActive() and engine.settings:bookLinked()
    if selected[provider.key] then count = count + 1 end
  end
  if count == 0 then
    UIManager:show(InfoMessage:new {
      text = _("Link this book to an active service before changing its status."),
      icon = "notice-warning",
    })
    return
  end
  self:_closeHome()
  local dialog
  local function choose(status_id)
    self.app:onShelfSyncSetCommonStatus(status_id, function()
      if self.status_dialog == dialog then
        dialog:onClose()
      end
    end, selected)
  end

  dialog = ButtonDialog:new {
    title = _("Reading status"),
    title_align = "left",
    use_info_style = false,
    width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9),
    buttons = {
      {
        {
          id = "to_read",
          text = _(STATUS.STATUS_NAME[STATUS.STATUS.TO_READ]),
          font_size = 18,
          font_bold = false,
          callback = function() choose(STATUS.STATUS.TO_READ) end,
        },
        {
          id = "reading",
          text = _(STATUS.STATUS_NAME[STATUS.STATUS.READING]),
          font_size = 18,
          font_bold = false,
          callback = function() choose(STATUS.STATUS.READING) end,
        },
      },
      {
        {
          id = "finished",
          text = _(STATUS.STATUS_NAME[STATUS.STATUS.FINISHED]),
          font_size = 18,
          font_bold = false,
          callback = function() choose(STATUS.STATUS.FINISHED) end,
        },
      },
      {
        { text = _(STATUS.STATUS_NAME[STATUS.STATUS.PAUSED]),
          font_size = 18, font_bold = false,
          callback = function() choose(STATUS.STATUS.PAUSED) end },
        { text = _(STATUS.STATUS_NAME[STATUS.STATUS.DNF]),
          font_size = 18, font_bold = false,
          callback = function() choose(STATUS.STATUS.DNF) end },
      },
      {
        {
          id = "provider_status",
          text = _("Choose services"),
          font_size = 17,
          font_bold = false,
          callback = function() self:_showStatusServices(selected) end,
        },
        {
          id = "back",
          text = _("Back"),
          font_size = 18,
          font_bold = false,
          callback = function() dialog:onClose() end,
        },
      },
    },
    tap_close_callback = function()
      if self.status_dialog == dialog then
        self.status_dialog = nil
      end
      self:show()
    end,
  }
  self.status_dialog = dialog
  UIManager:show(dialog)
end

function Dashboard:_showStatusServices(selected)
  local buttons = {}
  for _index, provider in ipairs(PROVIDERS) do
    local engine = self.app.engines[provider.key]
    table.insert(buttons, { {
      text = _(provider.label),
      enabled = engine:isActive() and engine.settings:bookLinked(),
      checked_func = function() return selected[provider.key] == true end,
      callback = function() selected[provider.key] = not selected[provider.key] end,
    } })
  end
  local dialog
  table.insert(buttons, { { text = _("Done"), callback = function() dialog:onClose() end } })
  dialog = ButtonDialog:new { title = _("Apply status to"), buttons = buttons }
  UIManager:show(dialog)
end

function Dashboard:_showLinkPicker()
  self:_closeHome()
  self.app.manual_link_dialog:show(nil, nil, function() self:show() end)
end

function Dashboard:_showProvidersMenu()
  self:_showMenu(_("Connections"), DashboardMenus.connections(self.app))
end

function Dashboard:_showTrackingMenu()
  if #self:_linkedEngines() == 0 then
    UIManager:show(InfoMessage:new { text = _("Link this book to a service first."), icon = "notice-warning" })
    return
  end
  self:_showMenu(_("Automatic tracking"), DashboardMenus.tracking(self.app))
end

function Dashboard:_showBookOptions()
  self:_showMenu(_("Book options"), DashboardMenus.bookOptions(self.app))
end

function Dashboard:_showSettingsMenu()
  self:_showMenu(_("ShelfSync settings"), DashboardMenus.settings(self.app))
end

function Dashboard:_showAbout()
  local Font = require("ui/font")
  local Github = require("shelfsync/lib/common/github")
  local VERSION = require("shelfsync_version")

  local info = Github:fetchVersionInfo()
  local version = table.concat(VERSION, ".")
  local latest = ""
  if info and info.plugin_version and Github:isNewer(info.plugin_version) then
    latest = " (latest v" .. info.plugin_version .. ")"
  end

  UIManager:show(InfoMessage:new {
    text = [[
ShelfSync plugin
v]] .. version .. latest .. [[

Synchronizes reading progress, notes, and status to The StoryGraph, Hardcover, Goodreads, Fable, Pagebound, and/or LibraryThing.

Project:
github.com/Lyfts/ShelfSync]],
    face = Font:getFace("cfont", 18),
    show_icon = false,
  })
end

function Dashboard:_showMenu(title, item_table)
  self:_closeHome()

  local Menu = require("ui/widget/menu")
  local function fillMenuItemText(items)
    for _index, item in ipairs(items or {}) do
      if not item._shelfsync_prepared then
        local original_text, original_func = item.text, item.text_func
        if item.checked_func or item.enabled_func then
          item.text_func = function()
            local label = original_func and original_func() or original_text or ""
            if item.checked_func then
              label = (item.checked_func() and "☑  " or "☐  ") .. label
            end
            if item.enabled_func and not item.enabled_func() then
              label = label .. "  ·  " .. _("Unavailable")
            end
            return label
          end
        end
        item._shelfsync_prepared = true
      end
      if not item.text and item.text_func then
        item.text = item.text_func()
      end
    end
  end
  fillMenuItemText(item_table)

  local menu
  menu = Menu:new {
    title = title,
    items_per_page = 10,
    items_font_size = 22,
    item_table = item_table,
    onMenuSelect = function(menu_instance, item)
      if item.enabled == false or (item.enabled_func and not item.enabled_func(menu_instance)) then
        return true
      end
      Trapper:wrap(function()
        if item.sub_item_table_func then
          item.sub_item_table = item.sub_item_table_func(menu_instance)
        end
        if self.menu_dialog ~= menu_instance then return end
        fillMenuItemText(item.sub_item_table)
        Menu.onMenuSelect(menu_instance, item)
      end)
      return true
    end,
    onMenuChoice = function(menu_instance, item)
      if item.callback then
        item.callback(menu_instance)
        menu_instance:updateItems()
      end
      return true
    end,
    updateItems = function(menu_instance, ...)
      fillMenuItemText(menu_instance.item_table)
      return Menu.updateItems(menu_instance, ...)
    end,
    onMenuHold = function(menu_instance, item)
      if item.hold_callback and (not item.enabled_func or item.enabled_func(menu_instance)) then
        item.hold_callback(menu_instance)
      end
      return true
    end,
    onCloseAllMenus = function(menu_instance)
      menu_instance._shelfsync_open = false
      UIManager:close(menu_instance)
      if self.menu_dialog == menu_instance then self.menu_dialog = nil end
      self:show()
      return true
    end,
  }
  menu._shelfsync_open = true
  self.menu_dialog = menu
  UIManager:show(menu)
end

return Dashboard
