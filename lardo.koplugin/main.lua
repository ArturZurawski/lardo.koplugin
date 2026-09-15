--[[--
Lardo: Mealie recipes for KOReader.

Browses a self-hosted Mealie instance and shows recipes as plain text, with
everything reachable from the D-pad and the keyboard, so it is usable on a
Kindle Keyboard. Recipes are cached on the device, and the plugin can take over
as KOReader's start-up screen ("Start with: Lardo").

@module koplugin.lardo
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local LardoApi = require("lardoapi")
local LardoConfig = require("lardoconfig")
local LardoLang = require("lardolang")
local LardoView = require("lardoview")
local Recipe = require("lardorecipe")
local RecipeBrowser = require("lardobrowser")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
-- our own translations first, KOReader's gettext for anything they miss
local LardoI18N = require("lardoi18n")
local _ = LardoI18N.gettext
local N_ = LardoI18N.ngettext

--- Optional widgets: required on demand so that a KOReader build without them
-- costs us one menu entry rather than the whole plugin (a failing require in
-- main.lua means PluginLoader drops us entirely, with only a log line).
local function optionalWidget(name)
    local ok, widget = pcall(require, name)
    if ok then return widget end
    logger.warn("Lardo: this KOReader has no", name)
    return nil
end

local START_WITH_VALUE = "lardo"

local DEFAULT_FONT_SIZE = 20
local DEFAULT_PROGRESS_POSITION = "top"
-- setting value and its English label; the label is translated where it is
-- shown, not here, or it would freeze in the language of the first run
local PROGRESS_POSITIONS = {
    { "top",    "Under the chapters" },
    { "bottom", "Bottom edge" },
    { "side",   "Right edge, whole recipe" },
    { "off",    "Hidden" },
}

-- setting value and its English label, translated where it is shown
local DEFAULT_SORT_ORDER = "name"
local SORT_ORDERS = {
    { "name",      "Name" },
    { "added",     "Newest first" },
    { "updated",   "Recently changed" },
    { "favorites", "Favourites first" },
}

-- reader.lua opens the file manager once at start-up; only that first instance
-- of the plugin should take over the screen.
local start_screen_handled = false

-- Likewise, "Download the recipe list at start-up" is once per KOReader run,
-- not once per plugin instance; it also stands in for the refresh the list does
-- when it opens with nothing in it, so start-up cannot download twice.
local startup_refresh_done = false

-- KOReader instantiates the plugin once for the file manager and once for the
-- reader. They must share one settings object, or whichever flushes last wins
-- and a font picked in one of them is silently lost.
local shared_settings, shared_cache

local Lardo = WidgetContainer:extend{
    name = "lardo",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/lardo.lua",
    -- the recipe index (what the server lists) and one stamp per stored recipe
    cache_file = DataStorage:getSettingsDir() .. "/lardo_cache.lua",
    -- the recipes themselves, one file each; see "The recipe store" below
    recipes_dir = DataStorage:getSettingsDir() .. "/lardo_recipes",
}

--==========================================================================
-- Settings, configuration file and cache
--==========================================================================

--- Cheap change detector for the configuration file (they are a few lines long).
local function checksum(text)
    local sum = 0
    for i = 1, #text do
        sum = (sum * 31 + text:byte(i)) % 4294967296
    end
    return string.format("%d:%08x", #text, sum)
end

--- Makes flush() a no-op unless something was actually saved since the last one.
--
-- KOReader broadcasts FlushSettings from Device:_beforeSuspend(), which is to
-- say every time the screensaver comes on, and LuaSettings:flush() rewrites the
-- whole file every single time it is called: the old one is renamed aside, the
-- entire table is serialized and the result is written with an fsync. Our cache
-- holds every recipe ever downloaded, so that was the device serializing and
-- writing the lot, onto a Kindle's slow flash, on its way into suspend -- with
-- input already inhibited, which is exactly what "it goes to sleep and then
-- stops responding" looks like. Recipes change on a refresh, not on a nap.
local function flushOnlyWhenChanged(settings)
    settings.lardo_dirty = false
    -- everything LuaSettings offers that changes the data, whether we use it
    -- today or not: missing one would mean a change that is never written
    local mutators = { "saveSetting", "delSetting", "makeTrue", "makeFalse",
        "makeNil", "toggle", "addTableItem", "removeTableItem" }
    for i = 1, #mutators do
        local name = mutators[i]
        local original = settings[name]
        if original then
            settings[name] = function(this, ...)
                this.lardo_dirty = true
                return original(this, ...)
            end
        end
    end
    local original_flush = settings.flush
    settings.flush = function(this, ...)
        if not this.lardo_dirty then return this end
        this.lardo_dirty = false
        return original_flush(this, ...)
    end
    return settings
end

function Lardo:loadSettings()
    if self.settings then return end
    -- PluginLoader puts our directory in .path; lardo.conf may sit there too.
    LardoConfig.plugin_dir = self.path
    if not shared_settings then
        shared_settings = flushOnlyWhenChanged(LuaSettings:open(self.settings_file))
        shared_cache = flushOnlyWhenChanged(LuaSettings:open(self.cache_file))
    end
    self.settings = shared_settings
    self.cache = shared_cache
    self.list = self.cache:readSetting("list") or {}
    self.stamps = self.cache:readSetting("stamps") or {}
    local stored_in_settings = self.cache:readSetting("recipes")
    if stored_in_settings then
        self:migrateRecipeCache(stored_in_settings)
    end
    self:importConfigFile(false)
    self:applyLanguage()
end

--- Reads lardo.conf, if present, and copies it into our settings.
-- The file wins whenever its contents changed since the last import, so
-- editing it over USB is enough; values edited in the UI survive otherwise.
-- @return boolean whether anything was imported, string path or nil
function Lardo:importConfigFile(force)
    local values, path, content = LardoConfig:read()
    if not values then
        self.conf_credentials = nil
        return false, nil
    end

    -- login credentials are kept in memory only, never written to settings
    if values.username and values.password then
        self.conf_credentials = { username = values.username, password = values.password }
    else
        self.conf_credentials = nil
    end

    local signature = checksum(content)
    if not force and self.settings:readSetting("conf_signature") == signature then
        return false, path
    end

    local imported = false
    if values.url then
        self.settings:saveSetting("url", values.url)
        imported = true
    end
    if values.token then
        self.settings:saveSetting("token", values.token)
        imported = true
    end
    if values.language then
        self.settings:saveSetting("language", values.language)
        self:applyLanguage()
        imported = true
    end
    self.settings:saveSetting("conf_signature", signature)
    self.settings:flush()
    logger.info("Lardo: imported configuration from", path)
    return imported, path
end

--- Mirrors a value the user changed in the UI back into lardo.conf, so the
-- file they see over USB never disagrees with what the plugin is using.
-- @return path it was written to, or nil
function Lardo:persistToConfigFile(updates)
    local path, content = LardoConfig:update(updates)
    if not path then
        logger.warn("Lardo: could not write the configuration file:", tostring(content))
        return nil
    end
    -- We just wrote it, so it must not count as "changed on the next start".
    self.settings:saveSetting("conf_signature", checksum(content))
    self.settings:flush()
    return path
end

function Lardo:getApi()
    return LardoApi.new(self.settings:readSetting("url"), self.settings:readSetting("token"),
        self:getLanguage())
end

--- Language tag sent to Mealie as Accept-Language, and used for our own
-- chapter titles. Mealie has no "language" setting in its API: it translates
-- each response according to that header, so one setting drives both sides.
function Lardo:getLanguage()
    local language = self.settings:readSetting("language")
    if type(language) == "string" and language ~= "" then
        return language
    end
    return self:getKOReaderLanguage()
end

--- KOReader's own interface language, as a tag Mealie understands ("pl_PL" is
-- how KOReader spells it, "pl-PL" is what goes into Accept-Language). This is
-- what "Follow KOReader" follows -- and what its label has to show, whatever
-- language is in force for us at the time.
function Lardo:getKOReaderLanguage()
    local ko_language = G_reader_settings:readSetting("language")
    if type(ko_language) == "string" and ko_language ~= "" then
        return (ko_language:gsub("_", "-"))
    end
    return "en-US"
end

--- One setting drives three things: the header we send to Mealie, the chapter
-- wording, and the plugin's own menus and messages.
function Lardo:applyLanguage()
    local language = self:getLanguage()
    LardoLang.set(language)
    LardoI18N.setLanguage(language)
end

--- KOReader builds its menu once and keeps it (FileManagerMenu.tab_item_table),
-- so anything captured at build time -- the help texts, our sub-menus -- would
-- stay in the old language until a restart. Dropping the cache makes the next
-- open rebuild it; the labels themselves are text_func, so they never go stale.
function Lardo:dropMenuCache()
    local menu = self.ui and self.ui.menu
    if menu and menu.tab_item_table then
        menu.tab_item_table = nil
    end
end

function Lardo:isConfigured()
    local url = self.settings:readSetting("url")
    return url ~= nil and url ~= ""
end

--- Logs in with the credentials from lardo.conf when we have no token yet.
function Lardo:ensureToken(api)
    if api:hasToken() then return true end
    if not self.conf_credentials then return false end
    local token, err = api:login(self.conf_credentials.username, self.conf_credentials.password)
    if not token then
        logger.warn("Lardo: automatic login failed:", err)
        return false
    end
    api.token = token
    self.settings:saveSetting("token", token)
    self.settings:flush()
    return true
end

--==========================================================================
-- The recipe store
--
-- One file per recipe, plus an index of stamps (slug -> updatedAt) that lives
-- in the cache file next to the recipe list.
--
-- Every recipe used to be a key in that one settings file, which meant KOReader
-- parsed the whole collection at start-up and kept it in memory for as long as
-- it ran. A Kindle Keyboard has 256 MB for everything, and none of that text is
-- needed to draw a list of names: the list comes from the index the server
-- sent, "is my copy current?" is answered by a stamp, and the recipe itself is
-- read when it is opened and let go of when the view closes.
--==========================================================================

--- Mealie slugs are already URL-safe; this is about what is unambiguous as a
-- file name on a Kindle's FAT filesystem, whatever a future Mealie sends.
local function recipeFileName(slug)
    local name = slug:gsub("[^%w%-_]", function(c)
        return string.format("~%02X", string.byte(c))
    end)
    return name .. ".lua"
end

function Lardo:recipePath(slug)
    return self.recipes_dir .. "/" .. recipeFileName(slug)
end

--- Creates the recipe directory on first use. @return whether we can write
function Lardo:ensureRecipesDir()
    if self.recipes_dir_ready then return true end
    if lfs.attributes(self.recipes_dir, "mode") ~= "directory" then
        lfs.mkdir(self.recipes_dir)
        if lfs.attributes(self.recipes_dir, "mode") ~= "directory" then
            logger.warn("Lardo: could not create", self.recipes_dir)
            return false
        end
    end
    self.recipes_dir_ready = true
    return true
end

--- Reads one recipe off the device. This is the only place that does, and it
-- runs when a recipe is opened -- never while drawing the list.
-- @return the recipe, or nil if it is not stored (or the file is unreadable,
--   which for a cache is the same thing: download it again)
function Lardo:getCachedRecipe(slug)
    if not slug or slug == "" then return nil end
    local ok, stored = pcall(dofile, self:recipePath(slug))
    if ok and type(stored) == "table" and stored.slug then
        return stored
    end
    -- Gone or unreadable, which for a cache is the same thing -- but the stamp
    -- has to go with it, or the next refresh would still think we have it.
    if self:cachedStamp(slug) ~= nil then
        logger.warn("Lardo: the stored recipe", slug, "could not be read")
        self:forgetRecipe(slug)
    end
    return nil
end

--- What the server said the stored copy was, without reading it.
function Lardo:cachedStamp(slug)
    return self.stamps and self.stamps[slug]
end

--- Whether the stored copy is older than what the server lists.
-- Mealie returns updatedAt on the cheap summary endpoint, so one list request
-- is enough to tell which recipes actually need downloading again -- and with
-- the stamps in the index, without touching a single stored recipe.
-- @param stamp the stored recipe's updatedAt, or nil if we have no copy
local function isStale(summary, stamp)
    if stamp == nil then return true end
    if summary.updated_at == "" then
        return false -- nothing to compare against; don't re-download blindly
    end
    return stamp ~= summary.updated_at
end
Lardo.isStale = function(_self, summary, stamp) return isStale(summary, stamp) end

--- Drops stored recipes the server no longer lists.
-- @return number of recipes removed
function Lardo:pruneCache()
    if #self.list == 0 then
        return 0 -- no list means no knowledge, not "everything was deleted"
    end
    local on_server = {}
    for i = 1, #self.list do
        on_server[self.list[i].slug] = true
    end
    local removed = 0
    for slug in pairs(self.stamps) do
        if not on_server[slug] then
            -- clearing the key we are standing on is the one mutation
            -- Lua allows during a pairs() traversal
            os.remove(self:recipePath(slug))
            self.stamps[slug] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        self.cache:saveSetting("stamps", self.stamps)
    end
    return removed
end

--- Stores one recipe and stamps it. @return whether it was written
function Lardo:cacheRecipe(recipe, no_flush)
    if not self:ensureRecipesDir() then return false end
    local path = self:recipePath(recipe.slug)
    local file, err = io.open(path, "wb")
    if not file then
        logger.warn("Lardo: could not store", path, err)
        return false
    end
    -- the same shape LuaSettings writes, so it can be read back with dofile()
    file:write("-- ", path, "\nreturn ", dump(recipe), "\n")
    file:close()
    self.stamps[recipe.slug] = recipe.updated_at or ""
    self.cache:saveSetting("stamps", self.stamps)
    if not no_flush then
        self.cache:flush()
    end
    return true
end

function Lardo:forgetRecipe(slug)
    os.remove(self:recipePath(slug))
    if self.stamps then
        self.stamps[slug] = nil
        self.cache:saveSetting("stamps", self.stamps)
    end
end

function Lardo:forgetAllRecipes()
    for slug in pairs(self.stamps or {}) do
        os.remove(self:recipePath(slug))
    end
    self.stamps = {}
    self.cache:saveSetting("stamps", self.stamps)
    self.cache:flush()
end

function Lardo:countCachedRecipes()
    local count = 0
    for _slug in pairs(self.stamps or {}) do -- luacheck: ignore _slug
        count = count + 1
    end
    return count
end

--- Moves a cache written by an earlier Lardo -- every recipe in one settings
-- file -- into one file per recipe. Once, on the first start after the update.
function Lardo:migrateRecipeCache(stored)
    local moved = 0
    for slug, recipe in pairs(stored) do
        if type(recipe) == "table" and type(slug) == "string" then
            recipe.slug = recipe.slug ~= "" and recipe.slug or slug
            if self:cacheRecipe(recipe, true) then moved = moved + 1 end
        end
    end
    self.cache:delSetting("recipes")
    self.cache:saveSetting("stamps", self.stamps)
    self.cache:flush()
    logger.info("Lardo: moved", moved, "recipes into", self.recipes_dir)
end

--==========================================================================
-- Plugin plumbing
--==========================================================================

function Lardo:onDispatcherRegisterActions()
    Dispatcher:registerAction("lardo_recipes", {
        category = "none",
        event = "ShowLardoRecipes",
        title = _("Lardo: recipes"),
        general = true,
    })
    -- so the ingredients can be put on any key via the Hotkeys plugin
    Dispatcher:registerAction("lardo_ingredients", {
        category = "none",
        event = "ShowLardoIngredients",
        title = _("Lardo: jump to the ingredients"),
        general = true,
    })
end

function Lardo:init()
    self:loadSettings()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- "Start with: Lardo": reader.lua always instantiates the file
    -- manager first and lets the chosen start-up module open on top of it, so
    -- closing us lands the user in the file browser instead of quitting.
    if not start_screen_handled
            and self.document == nil -- only ReaderUI passes a document to its plugins
            and G_reader_settings:readSetting("start_with") == START_WITH_VALUE then
        start_screen_handled = true
        UIManager:nextTick(function()
            self:showBrowser()
        end)
    end

    if not startup_refresh_done
            and self.document == nil
            and self.settings:isTrue("auto_refresh")
            and self:isConfigured() then
        startup_refresh_done = true
        UIManager:nextTick(function() self:refreshList() end)
    end
end

function Lardo:onShowLardoRecipes()
    self:showBrowser()
    return true
end

function Lardo:onShowLardoIngredients()
    if not self.viewer or not self.viewer.onLardoIngredients then return false end
    self.viewer:onLardoIngredients()
    return true
end

--==========================================================================
-- Menus
--==========================================================================

--- Adds "Lardo" to Settings ▸ File browser ▸ Start with.
function Lardo:injectStartWith(menu_items)
    local start_with = menu_items.start_with
    if not start_with or not start_with.sub_item_table then return end

    table.insert(start_with.sub_item_table, {
        text = _("Lardo"),
        radio = true,
        checked_func = function()
            return G_reader_settings:readSetting("start_with") == START_WITH_VALUE
        end,
        callback = function()
            G_reader_settings:saveSetting("start_with", START_WITH_VALUE)
        end,
    })

    -- The core label only knows about the built-in choices.
    local original_text_func = start_with.text_func
    start_with.text_func = function()
        if G_reader_settings:readSetting("start_with") == START_WITH_VALUE then
            return T(_("Start with: %1"), _("Lardo"))
        end
        return original_text_func()
    end
end

function Lardo:addToMainMenu(menu_items)
    menu_items.lardo = {
        -- text_func is what gets drawn (Menu.getMenuText prefers it, so the
        -- entry follows a language change); text is for MenuSorter, which sorts
        -- and tags the top-level entries by their plain text.
        text = _("Lardo"),
        text_func = function() return _("Lardo") end,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function() return _("Browse recipes") end,
                callback = function() self:showBrowser() end,
            },
            -- No "Filter recipes" here: filtering only makes sense with the
            -- list on screen, and there it is a keystroke away (or Menu ->
            -- Filter recipes). A second way in through the Tools menu only
            -- opened the list to immediately cover it with a box.
            {
                text_func = function() return _("Refresh recipes from the server") end,
                help_text = _("Fetches the list, and with it every recipe that is new or has changed, so everything is readable without WiFi afterwards."),
                keep_menu_open = true,
                separator = true,
                callback = function() self:refreshList() end,
            },
            {
                text_func = function()
                    local url = self.settings:readSetting("url")
                    return T(_("Connection: %1"), (url and url ~= "") and url or _("not set"))
                end,
                sub_item_table = self:getConnectionMenuTable(),
            },
            {
                text_func = function()
                    return T(N_("Offline: %1 recipe stored", "Offline: %1 recipes stored",
                        self:countCachedRecipes()), self:countCachedRecipes())
                end,
                sub_item_table = self:getOfflineMenuTable(),
                separator = true,
            },
            {
                text_func = function() return _("View") end,
                sub_item_table = self:getViewMenuTable(),
            },
            {
                text_func = function()
                    return T(_("Language: %1"), LardoLang.nameFor(self:getLanguage()))
                end,
                sub_item_table = self:getLanguageMenuTable(),
                separator = true,
            },
            {
                text_func = function() return _("Open Lardo instead of the file browser at start-up") end,
                checked_func = function()
                    return G_reader_settings:readSetting("start_with") == START_WITH_VALUE
                end,
                callback = function()
                    if G_reader_settings:readSetting("start_with") == START_WITH_VALUE then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    else
                        G_reader_settings:saveSetting("start_with", START_WITH_VALUE)
                    end
                end,
            },
        },
    }
    self:injectStartWith(menu_items)
end

--- The name of a font file, as it is shown to the user.
local function fontName(file)
    if not file then return nil end
    return file:match("([^/]+)%.%w+$") or file:match("([^/]+)$")
end

local function progressPositionLabel(current)
    for i = 1, #PROGRESS_POSITIONS do
        if PROGRESS_POSITIONS[i][1] == current then
            return _(PROGRESS_POSITIONS[i][2])
        end
    end
    return current
end

--- How everything Lardo shows is drawn: the font (recipes *and* the recipe
-- list, it is one setting) and the recipe view's own furniture.
--
-- One definition, used by KOReader's menu and by the menu of the open recipe --
-- they are the same settings, so there is no second place to keep in step. Every
-- label carries its current value, so nothing has to be opened to see how things
-- are set.
--
-- Each entry: text_func, callback(on_change), and optionally help_text,
-- enabled_func, separator and an id. `on_change` is called once the value has
-- actually changed, which for the entries that open a dialog is later.
function Lardo:getViewSettings()
    return {
        {
            id = "font_size",
            text_func = function() return T(_("Font size: %1"), self:getFontSize()) end,
            help_text = _("Used for the recipes and for the recipe list."),
            callback = function(on_change) self:showFontSizeDialog(on_change) end,
        },
        {
            id = "font_face",
            text_func = function()
                return T(_("Typeface: %1"),
                    fontName(self.settings:readSetting("font_face")) or _("KOReader default"))
            end,
            help_text = _("Used for the recipes and for the recipe list."),
            callback = function(on_change) self:showFontChooser(on_change) end,
        },
        {
            id = "font_reset",
            text_func = function() return _("Use KOReader's default typeface") end,
            enabled_func = function() return self.settings:readSetting("font_face") ~= nil end,
            separator = true,
            callback = function(on_change)
                self:applyViewSetting("font_face", nil, "font_face")
                if on_change then on_change() end
            end,
        },
        {
            id = "progress_position",
            text_func = function()
                return T(_("Reading position bar: %1"),
                    progressPositionLabel(self:getProgressPosition()))
            end,
            callback = function(on_change) self:showProgressPositionDialog(on_change) end,
        },
        {
            id = "show_buttons",
            text_func = function()
                return T(_("Button row at the bottom: %1"),
                    self:getShowButtons() and _("shown") or _("hidden"))
            end,
            help_text = _("On a touch screen it starts out shown; the same things are on the header and on a long press."),
            callback = function(on_change)
                self.settings:saveSetting("show_buttons", not self:getShowButtons())
                self.settings:flush()
                self:reopenViewer() -- the button row changes the layout and the keys
                if on_change then on_change() end
            end,
        },
    }
end

function Lardo:getViewMenuTable()
    local items = {}
    local settings = self:getViewSettings()
    for i = 1, #settings do
        local setting = settings[i]
        table.insert(items, {
            text_func = setting.text_func,
            help_text = setting.help_text,
            enabled_func = setting.enabled_func,
            separator = setting.separator,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                setting.callback(function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        })
    end
    return items
end

--- Mealie translates its answers from the Accept-Language header we send, and
-- the same setting picks the wording of the recipe chapters.
function Lardo:getLanguageMenuTable()
    local function useLanguage(tag)
        self.settings:saveSetting("language", tag)
        self.settings:flush()
        self:applyLanguage()
        self:persistToConfigFile({ language = tag or "" })
        self:reopenViewer() -- chapter titles come from the language
        self:dropMenuCache() -- ...and so do the menus
        self:updateBrowserItems() -- and the list's own title and hints
    end

    local items = {
        {
            text_func = function()
                return T(_("Follow KOReader (%1)"), LardoLang.nameFor(self:getKOReaderLanguage()))
            end,
            radio = true,
            checked_func = function() return self.settings:readSetting("language") == nil end,
            separator = true,
            callback = function() useLanguage(nil) end,
        },
    }
    local choices = LardoLang.choices()
    for i = 1, #choices do
        local tag, name = choices[i][2], choices[i][3]
        table.insert(items, {
            text = name,
            radio = true,
            checked_func = function() return self.settings:readSetting("language") == tag end,
            callback = function() useLanguage(tag) end,
        })
    end
    return items
end

--- Everything needed to reach the server: where it is, how we authenticate,
-- and the file those two can come from.
function Lardo:getConnectionMenuTable()
    return {
        {
            text_func = function()
                local path = LardoConfig:findFile()
                return path and T(_("Configuration file: %1"), path)
                    or _("Configuration file: none yet")
            end,
            keep_menu_open = true,
            callback = function() self:showConfigFileDialog() end,
        },
        {
            text_func = function() return _("Reload configuration file") end,
            keep_menu_open = true,
            separator = true,
            callback = function() self:reloadConfigFile() end,
        },
        {
            text_func = function() return _("Server address") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:editServerUrl(touchmenu_instance) end,
        },
        {
            text_func = function() return _("Log in with username and password") end,
            keep_menu_open = true,
            callback = function() self:promptLogin() end,
        },
        {
            text_func = function() return _("Enter API token manually") end,
            keep_menu_open = true,
            separator = true,
            callback = function() self:editToken() end,
        },
        {
            text_func = function() return _("Test connection") end,
            keep_menu_open = true,
            callback = function() self:testConnection() end,
        },
    }
end

function Lardo:getOfflineMenuTable()
    return {
        {
            text_func = function()
                local time = self.cache:readSetting("list_time")
                return time and T(_("Recipe list updated: %1"), os.date("%Y-%m-%d %H:%M", time))
                    or _("Recipe list was never downloaded")
            end,
            enabled_func = function() return false end,
        },
        {
            text_func = function() return _("Refresh at start-up") end,
            help_text = _("Refreshes once, when KOReader starts. WiFi is brought up the way KOReader's own settings say, and handed back afterwards."),
            checked_func = function() return self.settings:isTrue("auto_refresh") end,
            separator = true,
            callback = function()
                self.settings:saveSetting("auto_refresh", not self.settings:isTrue("auto_refresh"))
                self.settings:flush()
            end,
        },
        {
            text_func = function() return _("Delete downloaded recipes") end,
            keep_menu_open = true,
            callback = function() self:clearCache() end,
        },
    }
end

--==========================================================================
-- Configuration dialogs
--==========================================================================

function Lardo:showError(message)
    UIManager:show(InfoMessage:new{
        text = message or _("Something went wrong."),
        icon = "notice-warning",
    })
end

function Lardo:showConfigFileDialog()
    local path = LardoConfig:findFile()
    if path then
        UIManager:show(InfoMessage:new{
            text = T(_("Lardo reads its server address and API token from:\n\n%1\n\nEdit it over USB, then choose \"Reload configuration file\"."), path),
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("No configuration file found.\n\nLardo looks for lardo.conf in:\n%1\n\nCreate a template at the first of those? You can then fill in the server address and the API token over USB, without typing them on the device."),
            LardoConfig:describeSearchPaths()),
        ok_text = _("Create"),
        ok_callback = function()
            local written, err = LardoConfig:writeTemplate()
            if written then
                UIManager:show(InfoMessage:new{
                    text = T(_("Created:\n%1\n\nFill it in over USB, then choose \"Reload configuration file\"."), written),
                })
            else
                self:showError(T(_("Could not write the configuration file:\n%1"), tostring(err)))
            end
        end,
    })
end

function Lardo:reloadConfigFile()
    local imported, path = self:importConfigFile(true)
    if not path then
        self:showConfigFileDialog()
        return
    end
    if imported then
        UIManager:show(InfoMessage:new{
            text = T(_("Loaded settings from:\n%1"), path),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Read %1, but it contains no server address or token."), path),
        })
    end
end

function Lardo:editServerUrl(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Mealie server address"),
        input = self.settings:readSetting("url") or "",
        input_hint = "http://192.168.1.10:9000",
        description = _("Address of your Mealie instance, including the port."),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText()
                    UIManager:close(dialog)
                    self.settings:saveSetting("url", url ~= "" and url or nil)
                    self.settings:flush()
                    local path = self:persistToConfigFile({ url = url })
                    if path then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Saved to:\n%1"), path),
                            timeout = 3,
                        })
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Lardo:editToken()
    local dialog
    dialog = InputDialog:new{
        title = _("Mealie API token"),
        input = self.settings:readSetting("token") or "",
        description = _("Tokens are long. It is usually easier to put it in lardo.conf over USB, or to log in with your username and password."),
        allow_newline = false,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local token = dialog:getInputText()
                    UIManager:close(dialog)
                    self.settings:saveSetting("token", token ~= "" and token or nil)
                    self.settings:flush()
                    local path = self:persistToConfigFile({ token = token })
                    if path then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Saved to:\n%1"), path),
                            timeout = 3,
                        })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Lardo:promptLogin()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to Mealie"),
        fields = {
            {
                text = self.settings:readSetting("url") or "",
                hint = _("Server address"),
            },
            {
                text = self.conf_credentials and self.conf_credentials.username or "",
                hint = _("Username or email"),
            },
            {
                text = self.conf_credentials and self.conf_credentials.password or "",
                text_type = "password",
                hint = _("Password"),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Log in"),
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    self:doLogin(fields[1], fields[2], fields[3])
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Lardo:doLogin(url, username, password)
    if url == nil or url == "" then
        self:showError(_("Please enter the Mealie server address."))
        return
    end
    self.settings:saveSetting("url", url)
    self.settings:flush()

    self:runOnline(function()
        Trapper:info(_("Logging in to Mealie…"))
        local api = LardoApi.new(url, nil)
        local token, err = api:login(username or "", password or "")
        Trapper:clear()
        if not token then
            self:showError(err)
            return
        end
        self.settings:saveSetting("token", token)
        self.settings:flush()
        local path = self:persistToConfigFile({ url = url, token = token })
        UIManager:show(InfoMessage:new{
            text = path and T(_("Logged in. The API token has been saved to:\n%1"), path)
                or _("Logged in. The API token has been saved on the device."),
            timeout = 3,
        })
    end)
end

function Lardo:testConnection()
    -- Exactly the same opening as a refresh: re-read lardo.conf first, so that
    -- a server address just written over USB is tested (and the connection is
    -- brought up) instead of "not set up yet".
    self:loadSettings()
    self:importConfigFile(false)
    if not self:isConfigured() then
        self:promptSetup()
        return
    end
    self:runOnline(function()
        Trapper:info(_("Contacting the Mealie server…"))
        local api = self:getApi()
        self:ensureToken(api)
        local total, err = api:testConnection()
        Trapper:clear()
        if not total then
            self:showError(err)
            return
        end
        UIManager:show(InfoMessage:new{
            text = T(N_("Connected. %1 recipe on the server.", "Connected. %1 recipes on the server.", total), total),
            timeout = 3,
        })
    end, true) -- the link is enough: reaching Mealie is what we are here to find out
end

--- Shown when nothing is configured yet: points at the config file, because
-- typing a JWT on a Kindle keyboard is not something anybody should do.
function Lardo:promptSetup()
    local existing = LardoConfig:findFile()
    UIManager:show(ConfirmBox:new{
        text = existing
            and T(_("Lardo is not set up yet.\n\nPut your server address and API token into:\n%1"), existing)
            or T(_("Lardo is not set up yet.\n\nPut your server address and API token into lardo.conf, in any of:\n%1\n\nCreate that file now?"),
                LardoConfig:describeSearchPaths()),
        ok_text = _("Create file"),
        ok_callback = function()
            local written, err = LardoConfig:writeTemplate()
            if written then
                UIManager:show(InfoMessage:new{
                    text = T(_("Created:\n%1\n\nConnect the device over USB, fill in \"url\" and \"token\", then choose \"Reload configuration file\"."), written),
                })
            else
                self:showError(T(_("Could not write the configuration file:\n%1"), tostring(err)))
            end
        end,
        cancel_text = _("Enter manually"),
        cancel_callback = function()
            self:editServerUrl()
        end,
    })
end

--==========================================================================
-- Recipe list
--==========================================================================

local function sortOrderLabel(order)
    for i = 1, #SORT_ORDERS do
        if SORT_ORDERS[i][1] == order then return _(SORT_ORDERS[i][2]) end
    end
    return order
end

function Lardo:getSortOrder()
    local order = self.settings:readSetting("sort_by")
    for i = 1, #SORT_ORDERS do
        if SORT_ORDERS[i][1] == order then return order end
    end
    return DEFAULT_SORT_ORDER
end

--- Sorts the list in place. Name is the tie-breaker everywhere, so the order
-- never depends on what the server happened to send first.
-- @param lower recipe -> its lowercased name; a comparator is called O(n log n)
--   times and util.stringLower() is a UTF-8 pass over the string, so this is
--   handed in already memoized rather than called here.
local function sortRecipes(list, order, lower)
    local function byName(a, b)
        return lower(a) < lower(b)
    end
    local comparators = {
        name = byName,
        added = function(a, b)
            if (a.date_added or "") ~= (b.date_added or "") then
                return (a.date_added or "") > (b.date_added or "") -- newest first
            end
            return byName(a, b)
        end,
        updated = function(a, b)
            if (a.updated_at or "") ~= (b.updated_at or "") then
                return (a.updated_at or "") > (b.updated_at or "")
            end
            return byName(a, b)
        end,
        favorites = function(a, b)
            if (a.favorite or false) ~= (b.favorite or false) then
                return a.favorite == true
            end
            return byName(a, b)
        end,
    }
    table.sort(list, comparators[order] or byName)
end

--- The list in the order it is shown, plus one lowercased string per recipe to
-- match the filter against.
--
-- Both used to be built from scratch for every letter typed, and both are
-- expensive in the same way: util.stringLower() is a UTF-8 validation pass plus
-- a case fold, and the sort comparator called it twice per comparison. Typing
-- four letters on 300 recipes meant some 10 000 of those passes. Neither the
-- order nor the text changes while you type, so they are built once and kept
-- until the list is replaced or the sort order changes.
-- @return the sorted recipes, and the haystacks in the same order
function Lardo:sortedList()
    local order = self:getSortOrder()
    if self.sorted_list and self.sorted_source == self.list and self.sorted_order == order then
        return self.sorted_list, self.sorted_haystacks
    end

    local lowered = {}
    local function lower(recipe)
        local text = lowered[recipe]
        if not text then
            text = util.stringLower(recipe.name)
            lowered[recipe] = text
        end
        return text
    end

    local sorted = {}
    for i = 1, #self.list do sorted[i] = self.list[i] end
    sortRecipes(sorted, order, lower)

    -- name and description in one string: one find() per recipe per keystroke
    local haystacks = {}
    for i = 1, #sorted do
        local recipe = sorted[i]
        haystacks[i] = recipe.description ~= ""
            and (lower(recipe) .. "\n" .. util.stringLower(recipe.description))
            or lower(recipe)
    end

    self.sorted_list, self.sorted_haystacks = sorted, haystacks
    self.sorted_source, self.sorted_order = self.list, order
    return sorted, haystacks
end

function Lardo:buildItemTable()
    local sorted, haystacks = self:sortedList()
    local items = {}
    local shown = {}

    local filter = self.filter and util.stringLower(self.filter) or nil
    for i = 1, #sorted do
        local recipe = sorted[i]
        if not filter or haystacks[i]:find(filter, 1, true) then
            shown[#shown + 1] = recipe
            items[#items + 1] = {
                -- a star is worth more than the word "favourite" on a 600 px row
                text = recipe.favorite and ("\u{2605} " .. recipe.name) or recipe.name,
                mandatory = Recipe.listMandatory(recipe),
                recipe = recipe,
            }
        end
    end
    self.current_list = shown

    -- One line of chrome, and it earns its place: how many recipes there are,
    -- or -- once you start typing -- what you have typed and what it leaves.
    -- A second line saying "Lardo" would only cost recipes.
    local title
    if self.filtering or self.filter then
        title = T(_("Filter: %1_   %2/%3"), self.filter or "", #items, #self.list)
    else
        title = T(N_("%1 recipe in Mealie", "%1 recipes in Mealie", #items), #items)
    end

    if #items == 0 then
        table.insert(items, {
            text = filter and _("Nothing matches. Press Back to clear the filter.")
                or _("No recipes yet. Press Menu, then Refresh."),
            dim = true,
        })
    end
    return items, title
end

--- A letter typed on the recipe list, or "backspace" for the Del key.
function Lardo:filterKey(key)
    local filter = self.filter or ""
    if key == "backspace" then
        if filter == "" then
            self.filtering = false -- backspacing out of it leaves filter mode
            self:updateBrowserItems()
            return
        end
        filter = filter:sub(1, -2) -- the keyboard only ever sends us ASCII
    else
        filter = filter .. key
    end
    self.filtering = true
    self.filter = filter ~= "" and filter or nil
    self:updateBrowserItems()
end

--- "Filter recipes" from the menu: the filter box is the title bar itself, so
-- there is nothing to open -- it just starts listening, exactly as the first
-- keystroke would. A device without a keyboard gets the input dialog instead,
-- because there it is the only way to enter anything.
function Lardo:startFiltering()
    if not Device:hasKeyboard() then
        self:promptSearch()
        return
    end
    self.filtering = true
    self:updateBrowserItems()
end

function Lardo:showSortDialog()
    local dialog
    local buttons = {}
    for i = 1, #SORT_ORDERS do
        local order = SORT_ORDERS[i][1]
        local label = _(SORT_ORDERS[i][2])
        table.insert(buttons, {{
            text = (order == self:getSortOrder()) and ("\u{2713} " .. label) or label,
            callback = function()
                UIManager:close(dialog)
                self.settings:saveSetting("sort_by", order)
                self.settings:flush()
                self:updateBrowserItems()
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Sort recipes by"), buttons = buttons }
    UIManager:show(dialog)
end

--- @return boolean whether there was a filter to clear
function Lardo:clearFilter()
    if not self.filtering and not self.filter then return false end
    self.filtering = false
    self.filter = nil
    self:updateBrowserItems()
    return true
end

function Lardo:updateBrowserItems()
    if not self.browser then return end
    local items, title = self:buildItemTable()
    self.browser:switchItemTable(title, items, 1)
end

function Lardo:showBrowser()
    self:loadSettings()
    -- lardo.conf may have been edited over USB since we started; re-reading it
    -- is a few hundred bytes, and saves the user hunting for a menu entry.
    self:importConfigFile(false)
    -- KOReader loads the plugin twice (file manager and reader) and they share
    -- the cache object but not these two references: a refresh done from the
    -- other one would otherwise show here as yesterday's list.
    self.list = self.cache:readSetting("list") or self.list
    self.stamps = self.cache:readSetting("stamps") or self.stamps
    if self.browser then
        return
    end

    self.filter = nil
    self.filtering = false
    local items, title = self:buildItemTable()
    self.browser = RecipeBrowser:new{
        title = title,
        item_table = items,
        -- the list is read the same way the recipes are, so it uses the same font
        item_font_face = self.settings:readSetting("font_face"),
        item_font_size = self:getFontSize(),
        select_callback = function(recipe) self:openRecipe(recipe) end,
        menu_button_callback = function() self:showActionDialog() end,
        filter_callback = function(key) self:filterKey(key) end,
        clear_filter_callback = function() return self:clearFilter() end,
        keep_open_on_back = true,
        -- Menu has already closed itself by the time this runs.
        close_callback = function() self.browser = nil end,
    }
    UIManager:show(self.browser)

    if #self.list == 0 then
        if not self:isConfigured() then
            UIManager:nextTick(function() self:promptSetup() end)
        elseif not startup_refresh_done then
            -- unless the start-up download is already on its way with this
            UIManager:nextTick(function() self:refreshList() end)
        end
    end
end

function Lardo:showActionDialog()
    local dialog
    local function action(callback)
        return function()
            UIManager:close(dialog)
            callback()
        end
    end
    local buttons = {
        {{
            text = _("Filter recipes"),
            callback = action(function() self:startFiltering() end),
        }},
    }
    if self.filtering or self.filter then
        table.insert(buttons, {{
            text = _("Clear the filter"),
            callback = action(function() self:clearFilter() end),
        }})
    end
    table.insert(buttons, {{
        text = T(_("Sort by: %1"), sortOrderLabel(self:getSortOrder())),
        callback = action(function() self:showSortDialog() end),
    }})
    table.insert(buttons, {{
        text = _("Refresh from the server"),
        callback = action(function() self:refreshList() end),
    }})
    table.insert(buttons, {{
        text = _("Lardo settings"),
        callback = action(function() self:showSettingsDialog() end),
    }})
    table.insert(buttons, {{
        -- the only way out: Back stays inside Lardo on purpose
        text = _("Close Lardo"),
        callback = action(function()
            if self.browser then
                self.browser:onCloseAllMenus()
            end
        end),
    }})

    dialog = ButtonDialog:new{
        title = _("Lardo"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Lardo:showSettingsDialog()
    local dialog
    local function action(callback)
        return function()
            UIManager:close(dialog)
            callback()
        end
    end
    dialog = ButtonDialog:new{
        title = _("Lardo settings"),
        buttons = {
            -- the font is the list's font too, so it belongs on the list's menu
            {{ text = _("View and font"), callback = action(function() self:showViewMenu() end) }},
            {{ text = _("Configuration file"), callback = action(function() self:showConfigFileDialog() end) }},
            {{ text = _("Reload configuration file"), callback = action(function() self:reloadConfigFile() end) }},
            {{ text = _("Server address"), callback = action(function() self:editServerUrl() end) }},
            {{ text = _("Log in with username and password"), callback = action(function() self:promptLogin() end) }},
            {{ text = _("Test connection"), callback = action(function() self:testConnection() end) }},
            {{ text = _("Delete downloaded recipes"), callback = action(function() self:clearCache() end) }},
        },
    }
    UIManager:show(dialog)
end

function Lardo:promptSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Filter recipes"),
        input = self.filter or "",
        description = _("Filters the downloaded recipe list by name and description."),
        allow_newline = false,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Show all"),
                callback = function()
                    UIManager:close(dialog)
                    self:clearFilter()
                end,
            },
            {
                text = _("Filter"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    self.filter = (query and query ~= "") and query or nil
                    self.filtering = self.filter ~= nil
                    self:updateBrowserItems()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--==========================================================================
-- Network operations
--==========================================================================

--- Brings the connection up, runs `body` in a Trapper coroutine (so it can show
-- progress and be cancelled), and then hands back to KOReader's Wi-Fi settings.
--
-- That last step is the point of this function: NetworkMgr:runWhenOnline() only
-- brings the connection *up*; "Action when done" is acted on by
-- afterWifiAction(), and only if the plugin calls it -- without it, Wi-Fi stayed
-- on after every download, whatever the setting said. It runs even when `body`
-- failed, so a broken download cannot leave the radio on either.
-- @param link_is_enough when the task only needs the radio up, not a working
--   route to the internet. NetworkMgr:runWhenOnline() decides with a DNS lookup
--   and, when the link is up but that lookup fails, drops the callback without a
--   word; runWhenConnected() only wants the link and guarantees the callback
--   runs. "Test connection" wants exactly that -- whether the Mealie server
--   answers is the question it is asked to report on, not a reason to stay quiet.
function Lardo:runOnline(body, link_is_enough)
    local go = NetworkMgr.runWhenConnected and link_is_enough
        and function(cb) NetworkMgr:runWhenConnected(cb) end
        or function(cb) NetworkMgr:runWhenOnline(cb) end
    go(function()
        Trapper:wrap(function()
            local ok, err = pcall(body)
            if not ok then
                Trapper:clear()
                logger.err("Lardo: network task failed:", err)
                self:showError(T(_("Something went wrong:\n%1"), tostring(err)))
            end
            if NetworkMgr.afterWifiAction then
                -- a KOReader without it simply leaves WiFi alone, as before
                local done_ok, done_err = pcall(function() NetworkMgr:afterWifiAction() end)
                if not done_ok then
                    logger.warn("Lardo: afterWifiAction failed:", done_err)
                end
            end
        end)
    end)
end

--- Downloads the recipe index and drops what is gone from the server.
-- Must run inside a Trapper coroutine.
-- @return number of recipes removed from the device, or nil if the request failed
function Lardo:downloadList()
    local api = self:getApi()
    self:ensureToken(api)
    Trapper:info(_("Loading the recipe list from Mealie…"))
    local raw, err = api:getRecipeList()
    if not raw then
        Trapper:clear()
        self:showError(err)
        return nil
    end

    local list = {}
    for i = 1, #raw do
        local summary = Recipe.normalizeSummary(raw[i])
        if summary then
            table.insert(list, summary)
        end
    end

    -- Favourites are a property of the user, not of the recipe, so they come
    -- from their own endpoint. An old Mealie that does not have it just means
    -- no stars -- never a failed refresh.
    local ok, favorites = pcall(function() return api:getFavoriteIds() end)
    if ok and favorites then
        for i = 1, #list do
            list[i].favorite = list[i].id ~= "" and favorites[list[i].id] == true or nil
        end
    elseif not ok then
        logger.warn("Lardo: could not read the favourites:", favorites)
    end

    self.list = list
    local removed = self:pruneCache() -- saves the stamps itself if it dropped any
    self.cache:saveSetting("list", list)
    self.cache:saveSetting("list_time", os.time())
    self.cache:flush()
    self:updateBrowserItems() -- the names are on screen before the bodies arrive
    return removed
end

--- The only thing that talks to the server on purpose: the index, and then
-- every recipe that is missing or out of date.
--
-- These used to be two menu entries ("Refresh list" and "Sync all recipes"),
-- which was a distinction without a difference: the index is what tells us what
-- to fetch, and a recipe is a few kilobytes of text. One entry, one WiFi
-- session, one message at the end. Later refreshes cost only what changed,
-- because the index carries updatedAt.
function Lardo:refreshList()
    self:loadSettings()
    self:importConfigFile(false)
    if not self:isConfigured() then
        self:promptSetup()
        return
    end
    self:runOnline(function()
        local removed = self:downloadList()
        if not removed then return end -- it has said why itself
        local todo = self:pendingSync()
        local added, updated, failed = 0, 0, 0
        if #todo > 0 then
            added, updated, failed = self:downloadRecipes(todo)
        end
        Trapper:clear()
        self:reportRefresh(#self.list, added, updated, removed, failed)
    end)
end

function Lardo:openRecipe(summary)
    local index = 1
    for i = 1, #(self.current_list or {}) do
        if self.current_list[i].slug == summary.slug then
            index = i
            break
        end
    end
    self:showRecipeAt(index)
end

function Lardo:showRecipeAt(index)
    local summary = self.current_list and self.current_list[index]
    if not summary then return end

    -- The stamp says whether we have a copy and whether it is current; the
    -- file itself is only opened for the recipe we are about to show.
    local stamp = self:cachedStamp(summary.slug)
    local cached = stamp ~= nil and self:getCachedRecipe(summary.slug) or nil
    if cached and not isStale(summary, stamp) then
        self:displayRecipe(cached, index)
        return
    end
    -- The stored copy is out of date, but a stale recipe beats nagging about
    -- WiFi in the middle of cooking: only go online if we already are.
    if cached and not NetworkMgr:isOnline() then
        self:displayRecipe(cached, index)
        return
    end

    local function fetch()
        Trapper:info(T(_("Loading %1…"), summary.name))
        local api = self:getApi()
        self:ensureToken(api)
        local raw, err = api:getRecipe(summary.slug)
        Trapper:clear()
        local recipe = raw and Recipe.normalizeFull(raw)
        if not recipe then
            if cached then
                self:displayRecipe(cached, index) -- fall back to what we have
            else
                self:showError(raw and _("This recipe could not be read.") or err)
            end
            return
        end
        if recipe.updated_at == "" then
            recipe.updated_at = summary.updated_at
        end
        self:cacheRecipe(recipe)
        self:displayRecipe(recipe, index)
    end

    if cached then
        Trapper:wrap(fetch) -- already online, no WiFi prompt and nothing to hang up
    else
        self:runOnline(fetch)
    end
end

--==========================================================================
-- Reading view
--==========================================================================

function Lardo:getFontSize()
    return self.settings:readSetting("font_size") or DEFAULT_FONT_SIZE
end

--- The button row is chrome on a keyboard device, where every button has a key
-- of its own -- and the way around on a touch screen, where it is the only
-- visible one. Hence a default that follows the device until it is set.
function Lardo:getShowButtons()
    local shown = self.settings:readSetting("show_buttons")
    if shown == nil then return Device:isTouchDevice() end
    return shown == true
end

function Lardo:getProgressPosition()
    return self.settings:readSetting("progress_position") or DEFAULT_PROGRESS_POSITION
end

function Lardo:displayRecipe(recipe, index, chapter_index)
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.current_recipe = recipe
    self.current_index = index

    local chapters = Recipe.toChapters(recipe)
    local count = self.current_list and #self.current_list or 0

    -- Building our own view touches a fair amount of KOReader's widget API,
    -- which varies between versions. A failure here used to look like "nothing
    -- happens" when opening a recipe; now it says why.
    local ok, err = pcall(function()
        -- showRecipeAt() may have to hit the network, so the current recipe
        -- stays on screen until the next one is ready; it closes us then.
        local viewer
        viewer = LardoView:new{
            title = recipe.name,
            meta = Recipe.headerMeta(recipe),
            chapters = chapters,
            chapter_index = chapter_index or 1,
            font_size = self:getFontSize(),
            font_face = self.settings:readSetting("font_face"),
            progress_position = self:getProgressPosition(),
            show_buttons = self:getShowButtons(),
            next_recipe_callback = (count > 1) and function()
                self:showRecipeAt(index < count and index + 1 or 1)
            end or nil,
            prev_recipe_callback = (count > 1) and function()
                self:showRecipeAt(index > 1 and index - 1 or count)
            end or nil,
            menu_callback = function(view) self:showViewMenu(view) end,
            close_callback = function()
                if self.viewer == viewer then
                    self.viewer = nil
                    -- back on the list: the recipe's text can go, it is on the
                    -- device and the next open reads it again
                    self.current_recipe = nil
                end
            end,
        }
        self.viewer = viewer
        UIManager:show(viewer)
    end)
    if ok then return end

    self.viewer = nil
    logger.err("Lardo: could not open the recipe view:", err)
    -- There used to be a fallback to KOReader's TextViewer here. It was a trap:
    -- on a keyboard device its Close button cannot be reached, so a recipe
    -- opened in it could not be left. An error message is the honest answer.
    self:showError(T(_("Could not open the recipe view.\n\n%1"), tostring(err)))
end

--- Reopens the current recipe, keeping the chapter. Needed for settings that
-- change the key bindings (the button row claims Left/Right).
function Lardo:reopenViewer()
    local viewer = self.viewer
    if not viewer or not self.current_recipe then return end
    local chapter_index = viewer.chapter_index
    UIManager:close(viewer)
    self.viewer = nil
    self:displayRecipe(self.current_recipe, self.current_index, chapter_index)
end

--- Applies a setting that only affects the layout, in place.
function Lardo:applyViewSetting(key, value, viewer_field)
    self.settings:saveSetting(key, value)
    self.settings:flush()
    -- the fallback TextViewer has no rebuild(): its own menu handles fonts
    if self.viewer and self.viewer.rebuild then
        self.viewer[viewer_field] = value
        self.viewer:rebuild()
    end
    if key == "font_face" or key == "font_size" then
        self:applyBrowserFont()
    end
end

--- The font is a plugin-wide setting: the recipe list follows the recipes.
-- The list usually sits behind the open recipe, so it is refreshed in place
-- rather than reopened; a Menu that refuses to is not worth losing the list over.
function Lardo:applyBrowserFont()
    if not self.browser or not self.browser.setItemFont then return end
    local ok, err = pcall(function()
        self.browser:setItemFont(self.settings:readSetting("font_face"), self:getFontSize())
    end)
    if not ok then
        logger.warn("Lardo: could not apply the font to the recipe list:", err)
    end
end

local FONT_SIZE_BUTTON_ID = "lardo_font_size"

function Lardo:showViewMenu(viewer)
    local dialog
    local function action(callback)
        return function()
            UIManager:close(dialog)
            callback()
        end
    end
    -- the size sits between A- and A+, and is updated in place so the dialog
    -- does not have to be closed and reopened on every step
    local function stepFontSize(delta)
        self:changeFontSize(delta)
        local button = dialog and dialog.getButtonById and dialog:getButtonById(FONT_SIZE_BUTTON_ID)
        if button and button.setText then
            button:setText(tostring(self:getFontSize()), button.width)
            UIManager:setDirty(dialog, "ui")
        end
    end

    local buttons = {
        {
            {
                text = "A -",
                callback = function() stepFontSize(-1) end,
            },
            {
                id = FONT_SIZE_BUTTON_ID,
                text = tostring(self:getFontSize()),
                callback = action(function() self:showFontSizeDialog() end),
            },
            {
                text = "A +",
                callback = function() stepFontSize(1) end,
            },
        },
    }
    -- the same settings as in KOReader's menu, each one showing its value; the
    -- font size is already the button between A - and A +
    local settings = self:getViewSettings()
    for i = 1, #settings do
        local setting = settings[i]
        local usable = setting.id ~= "font_size"
            and (not setting.enabled_func or setting.enabled_func())
        if usable then
            table.insert(buttons, {{
                text = setting.text_func(),
                callback = action(function() setting.callback() end),
            }})
        end
    end

    dialog = ButtonDialog:new{
        title = viewer and viewer.title or _("View"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Lardo:changeFontSize(delta)
    local size = self:getFontSize() + delta
    if size < 12 then size = 12 elseif size > 40 then size = 40 end
    self:applyViewSetting("font_size", size, "font_size")
end

function Lardo:showFontSizeDialog(on_change)
    local SpinWidget = optionalWidget("ui/widget/spinwidget")
    if not SpinWidget then
        self:showError(_("This KOReader version has no number picker. Use the A- / A+ buttons in the recipe menu instead."))
        return
    end
    UIManager:show(SpinWidget:new{
        title_text = _("Font size"),
        value = self:getFontSize(),
        value_min = 12,
        value_max = 40,
        value_step = 1,
        value_hold_step = 4,
        default_value = DEFAULT_FONT_SIZE,
        callback = function(spin)
            self:applyViewSetting("font_size", spin.value, "font_size")
            if on_change then on_change() end
        end,
    })
end

--- Any font KOReader knows about. KOReader's own FontChooser puts its Close
-- and "Set font" buttons below a long scrolling radio list, which is awkward to
-- reach with a D-pad, so the fonts go into a Menu instead: Up/Down, page keys
-- and letter shortcuts all work, and picking one applies it straight away.
function Lardo:showFontChooser(on_change)
    local ok, FontList = pcall(require, "fontlist")
    if not ok then
        self:showError(_("This KOReader version does not expose its font list."))
        return
    end
    local name_of = select(2, pcall(function()
        return require("ui/widget/fontchooser").getFontNameText
    end))
    if type(name_of) ~= "function" then
        name_of = function() return nil end
    end

    local current = self.settings:readSetting("font_face")
    local items = {
        {
            text = _("KOReader default"),
            mandatory = current == nil and "\u{2713}" or nil,
            font_file = false, -- false, so that "chosen" is distinguishable from "no row"
        },
    }
    local fonts = FontList:getFontList()
    for i = 1, #fonts do
        local file = fonts[i]
        local name = name_of(file) or file:match("([^/]+)%.%w+$") or file
        table.insert(items, {
            text = name,
            mandatory = file == current and "\u{2713}" or nil,
            font_file = file,
            preview_font = file, -- the row is drawn in the font it offers
        })
    end

    local menu
    menu = RecipeBrowser:new{
        title = _("Typeface"),
        subtitle = _("Press a font to use it"),
        item_table = items,
        select_callback = function() end, -- unused, we override onMenuSelect below
        close_callback = function() menu = nil end,
    }
    menu.onMenuSelect = function(_self, item)
        UIManager:close(_self)
        if item.font_file ~= nil then
            self:applyViewSetting("font_face", item.font_file or nil, "font_face")
            if on_change then on_change() end
        end
        return true
    end
    UIManager:show(menu)
end

function Lardo:showProgressPositionDialog(on_change)
    local dialog
    local buttons = {}
    for i = 1, #PROGRESS_POSITIONS do
        local position, label = PROGRESS_POSITIONS[i][1], _(PROGRESS_POSITIONS[i][2])
        table.insert(buttons, {{
            text = (position == self:getProgressPosition()) and ("\u{2713} " .. label) or label,
            callback = function()
                UIManager:close(dialog)
                self:applyViewSetting("progress_position", position, "progress_position")
                if on_change then on_change() end
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Reading position bar"), buttons = buttons }
    UIManager:show(dialog)
end

--- What a refresh still has to fetch after the index: only recipes that are
-- missing or whose updatedAt moved, so one list request is enough to know --
-- and the stamps mean not one stored recipe has to be opened to work it out.
function Lardo:pendingSync()
    local todo = {}
    for i = 1, #self.list do
        local summary = self.list[i]
        local stamp = self:cachedStamp(summary.slug)
        if isStale(summary, stamp) then
            table.insert(todo, { summary = summary, is_update = stamp ~= nil })
        end
    end
    return todo
end

--- What the refresh did, in one message rather than two.
function Lardo:reportRefresh(available, added, updated, removed, failed)
    local parts = {
        T(N_("%1 recipe available.", "%1 recipes available.", available), available),
    }
    if added > 0 then
        table.insert(parts, T(N_("%1 recipe added.", "%1 recipes added.", added), added))
    end
    if updated > 0 then
        table.insert(parts, T(N_("%1 recipe updated.", "%1 recipes updated.", updated), updated))
    end
    if removed > 0 then
        table.insert(parts, T(N_("%1 recipe removed.", "%1 recipes removed.", removed), removed))
    end
    if failed > 0 then
        table.insert(parts, T(N_("%1 recipe failed.", "%1 recipes failed.", failed), failed))
    end
    if #parts == 1 then
        table.insert(parts, _("Everything was already up to date."))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 3 })
end

--- Downloads the recipes a refresh found missing or out of date. Must run
-- inside a Trapper coroutine: the progress message is what makes a long
-- download cancellable.
--
-- The message used to be redrawn for every single recipe, with its name on it.
-- That was the slow part of a sync, not the downloads: every `Trapper:info()`
-- builds an InfoMessage, repaints the screen (on e-ink an actual refresh) and
-- waits 100 ms to see whether it was dismissed -- easily more time than the few
-- kilobytes of JSON it was announcing. So: one message, a counter that moves at
-- most once a second, no names, and the summary at the end says what happened.
-- @return added, updated, failed
function Lardo:downloadRecipes(todo)
    local api = self:getApi()
    self:ensureToken(api)
    local added, updated, failed = 0, 0, 0
    local function progress(i, fast)
        -- fast_refresh keeps the same InfoMessage on screen instead of
        -- rebuilding it, which is what makes the repaint cheap.
        return Trapper:info(T(N_("Downloading %1 recipe…\n%2 of %1",
            "Downloading %1 recipes…\n%2 of %1", #todo), #todo, i), fast)
    end
    local go_on = progress(1)
    local tick = os.time()
    -- A request that cannot reach the server blocks for socketutil's timeouts
    -- (10 s per read, 30 s in total) and the whole of KOReader waits with it.
    -- The usual way to lose the network mid-sync is the device falling asleep,
    -- and then carrying on down the list means minutes of a Kindle that answers
    -- nothing. Three failures in a row is not a bad recipe, it is a connection
    -- that is gone: stop, keep what arrived, and let the next refresh pick up
    -- the rest -- which is exactly what it is built to do.
    local in_a_row = 0
    for i = 1, #todo do
        local entry = todo[i]
        if os.time() ~= tick then -- at most one redraw (and one dismiss check) a second
            tick = os.time()
            go_on = progress(i, true)
        end
        if not go_on then break end
        local raw = api:getRecipe(entry.summary.slug)
        local recipe = raw and Recipe.normalizeFull(raw)
        if recipe then
            in_a_row = 0
            if recipe.updated_at == "" then
                -- keep the list's stamp, or we would fetch it again forever
                recipe.updated_at = entry.summary.updated_at
            end
            self:cacheRecipe(recipe, true)
            if entry.is_update then
                updated = updated + 1
            else
                added = added + 1
            end
        else
            failed = failed + 1
            in_a_row = in_a_row + 1
            if in_a_row >= 3 then break end
        end
    end
    -- each recipe is already on the device; this is the index of stamps, once
    self.cache:flush()
    return added, updated, failed
end

function Lardo:clearCache()
    UIManager:show(ConfirmBox:new{
        text = _("Delete all recipes stored on this device?\nThey will be downloaded again when needed."),
        ok_text = _("Delete"),
        ok_callback = function()
            self:forgetAllRecipes()
            UIManager:show(InfoMessage:new{
                text = _("Downloaded recipes deleted."),
                timeout = 2,
            })
        end,
    })
end

--- KOReader asks every widget to save itself before a suspend, and again on its
-- own timer. Both of these write nothing at all unless something changed since
-- the last flush (see flushOnlyWhenChanged) -- a nap must not cost a rewrite of
-- every recipe on the device.
function Lardo:onFlushSettings()
    if self.settings then self.settings:flush() end
    if self.cache then self.cache:flush() end
end

return Lardo
