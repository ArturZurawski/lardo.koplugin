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
local DocumentRegistry = require("document/documentregistry")
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
local PluginShare = require("pluginshare")
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

--- Whether there is anything to arrange things with on this KOReader.
local function canArrange()
    return optionalWidget("ui/widget/sortwidget") ~= nil
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

-- How often the corner of an open recipe is redrawn while the screen is being
-- kept on, and 0 for "do not keep it on". A Kindle blanks the screen on a timer
-- of its own that the device has no setting for, which is what this is for.
--
-- The *poking* is on its own clock, below: how often the corner is worth
-- redrawing is a matter of taste, and how often the device has to be told is a
-- matter of the device.
local DEFAULT_KEEP_AWAKE = 10
-- Every four minutes, which is KOReader's own figure for this: its AutoSuspend
-- resets the same timer on the same clock, with the comment "lower than the
-- minimum t1 timeout" -- so five minutes is the shortest any Kindle allows, and
-- the ten-minute interval this used to poke on was simply too late on a device
-- set to five. (It also cannot help once the screensaver is already up: powerd
-- refuses the reset then.)
local KEEP_AWAKE_POKE_SECONDS = 4 * 60
local KEEP_AWAKE_INTERVALS = {
    { 0,  "Off" },
    { 5,  "Every 5 minutes" },
    { 10, "Every 10 minutes" },
    { 15, "Every 15 minutes" },
    { 30, "Every 30 minutes" },
}

-- What the corner of a recipe's header shows besides its cooking time.
local STATUS_ITEMS = {
    { "awake",   "Awake" },
    { "battery", "Battery" },
    { "clock",   "Clock" },
    { "wifi",    "Wi-Fi" },
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
    -- not ours: what a menu-customising plugin writes, which we only ever read
    -- to be able to name it (see menuOrderFile)
    menu_order_file = DataStorage:getSettingsDir() .. "/filemanager_menu_order.lua",
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
    self:forgetButtonRowSettings()
    self:importConfigFile(false)
    self:applyLanguage()
end

--- Both screens used to carry a row of buttons -- where it sat, which buttons
-- were on it, in what order -- and none of that is read any more: the filter is
-- the line at the top or the keyboard, the menu is a tap on that line or the
-- Menu key, and the way out is in the menu. Settings nothing reads are the
-- settings-file version of dead code, so they go out once, on the way in.
local BUTTON_ROW_SETTINGS = {
    "buttons_position", "view_buttons", "view_button_order",
    "list_buttons_position", "list_buttons", "list_button_order",
    "show_buttons",
}

function Lardo:forgetButtonRowSettings()
    local had_any = false
    for i = 1, #BUTTON_ROW_SETTINGS do
        if self.settings:readSetting(BUTTON_ROW_SETTINGS[i]) ~= nil then
            self.settings:saveSetting(BUTTON_ROW_SETTINGS[i], nil)
            had_any = true
        end
    end
    if had_any then self.settings:flush() end
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

--- One level deep: the depth `MenuSorter` mutates. It appends each tab's
-- children into the tab's own table, so a fresh table with the original fields
-- and no array part is exactly what "as it was before the sort" means.
local function copyMenuItems(items)
    local copy = {}
    for id, item in pairs(items) do
        if type(item) == "table" then
            local entry = {}
            for k, v in pairs(item) do entry[k] = v end
            copy[id] = entry
        else
            copy[id] = item
        end
    end
    return copy
end

--- Remembers KOReader's menu as it is before its sorter eats it.
--
-- The *skeleton* -- the row of tabs, and one entry per tab carrying its icon --
-- is built once, in `FileManagerMenu:init()`. `MenuSorter:sort` then consumes
-- the flat table: every item moves into its parent and is removed from the flat
-- one, and `item_table["KOMenu:menu_buttons"]` is dropped last of all. Up to
-- v2026.07 nothing ever put the skeleton back (newer versions re-create it at
-- the top of `setUpdateItemTable`), so a *second* build had no row of tabs to
-- sort and died on `ipairs(nil)` at menusorter.lua:139.
--
-- Nobody but us asks for a second build, so nobody but us has to fix this. We
-- are called before the first sort, which is the only moment the skeleton can
-- still be copied.
function Lardo:rememberMenuItems(menu_items)
    if self.pristine_menu_items or type(menu_items) ~= "table" then return end
    -- The row of tabs is what we are here to keep. A table without one is not
    -- the menu KOReader is about to sort, and copying it would leave us holding
    -- something we could not rebuild a menu from -- which is the failure we are
    -- trying to prevent, not a smaller version of it.
    if type(menu_items["KOMenu:menu_buttons"]) ~= "table" then return end
    self.pristine_menu_items = copyMenuItems(menu_items)
end

--- Makes KOReader build its menu again: a language change needs it (the help
-- texts and our sub-menus are captured at build time; the labels themselves are
-- `text_func`, so those never go stale), and so does switching our own tab on
-- or off, which changes the row of tabs itself.
--
-- Both halves have to go -- the sorted table and the flat one it was sorted
-- from -- and the flat one has to go back to what it was *before* the first
-- sort, or the build that follows has no menu to build. Everything else in it
-- (KOReader's own entries, every plugin's) is put back by `setUpdateItemTable`
-- on the way in, so a stale copy of those does no harm.
function Lardo:dropMenuCache()
    local menu = self.ui and self.ui.menu
    if not menu or not menu.tab_item_table then return end
    -- Without the snapshot there is nothing to rebuild from, and a menu that
    -- cannot be opened is worse than a tab that waits for the next start-up.
    if not self.pristine_menu_items then return end
    menu.tab_item_table = nil
    menu.menu_items = copyMenuItems(self.pristine_menu_items)
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
    self:registerProvider()
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
            -- Everything else a plugin does runs inside a pcall of KOReader's
            -- (PluginLoader for the load, FileManagerMenu for the menu) -- this
            -- does not: it is our own scheduled task, on the UI loop, at
            -- start-up. A failure here is a device that does not come up, so it
            -- is a failure we report and step out of the way of.
            local ok, err = pcall(function() self:showBrowser() end)
            if not ok then
                logger.err("Lardo: the recipe list could not be opened at start-up:", err)
                self:showError(T(_("Lardo could not open at start-up.\n\n%1"), tostring(err)))
            end
        end)
    end

    if not startup_refresh_done
            and self.document == nil
            and self.settings:isTrue("auto_refresh")
            and self:isConfigured() then
        startup_refresh_done = true
        UIManager:nextTick(function()
            local ok, err = pcall(function() self:refreshList() end)
            if not ok then
                logger.err("Lardo: the start-up refresh failed:", err)
            end
        end)
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

--==========================================================================
-- A tab of our own in KOReader's menu
--
-- KOReader's menu is a row of tabs with an icon each -- file browser, settings,
-- tools, search. They are not hardcoded: the row is `order["KOMenu:menu_buttons"]`
-- in `ui/elements/filemanager_menu_order`, a module `require` caches, and a tab
-- is simply an entry in `menu_items` carrying an `icon`, whose contents come
-- from `order[<its id>]` -- a list of ids of other entries.
--
-- So a plugin can have one: add the id to that row, list our entries' ids under
-- it, and publish each entry separately. Then Menu can open straight into it,
-- which is the point -- Tools -> More tools -> Lardo is three presses from a
-- screen that *is* Lardo.
--
-- Off by default: it is somebody else's menu, and a tab is a loud thing to add
-- to it uninvited.
--==========================================================================

local MENU_TAB_ID = "lardo"
-- the closest thing to a recipe book in KOReader's icon set
local MENU_TAB_ICON = "book.opened"

-- Once per KOReader process, at load time, before any menu is built: this is
-- how a contributed plugin gets into *Tools -> More tools*. It appends the id
-- to `more_tools` in both order modules, and an id that is in the **order** is
-- placed by MenuSorter instead of being swept up afterwards as an orphan -- and
-- is visible to a menu customiser, which reads those orders. Relying on the
-- orphan pass instead is what left Lardo out of the menu until it was opened
-- once, while every other plugin on the same device appeared straight away.
pcall(function() require("ui/plugin/insert_menu").add(MENU_TAB_ID) end)

function Lardo:usesOwnMenuTab()
    return self.settings:isTrue("own_menu_tab")
end

--- Set when this KOReader turned out not to keep the tab we added.
--
-- `MenuSorter:mergeAndSort` reads `settings/<prefix>_menu_order.lua` -- what a
-- menu customiser writes -- and copies it over the order module *after* every
-- plugin's `addToMainMenu` has run. A row we added ourselves while building is
-- therefore gone by the time the row is read: the tab cannot appear, and since
-- the tab publishes no entry under Tools either, what it published is swept up
-- as orphans into the first tab behind a "NEW: " prefix. Reachable, and nowhere
-- anybody would look for it.
--
-- Nothing can tell before the menu is built, so we look afterwards and stop
-- asking for the rest of the session. The *setting* is left alone: it is what
-- the user asked for, and another KOReader may well allow it.
local tab_refused = false
-- ...and whether we have already said that Lardo is not in the menu at all.
local menu_gap_reported = false

--- @return the shared menu order module, or nil on a KOReader without it
local function menuOrder()
    local ok, order = pcall(require, "ui/elements/filemanager_menu_order")
    if ok and type(order) == "table" and type(order["KOMenu:menu_buttons"]) == "table" then
        return order
    end
    return nil
end

--- Where our id sits in a list in the order: the row of tabs, or More tools.
local function positionIn(list)
    for i = 1, #(list or {}) do
        if list[i] == MENU_TAB_ID then return i end
    end
    return nil
end

local function tabRowPosition(order)
    return positionIn(order["KOMenu:menu_buttons"])
end

--- Under *Tools → More tools*, where every contributed plugin lives.
--
-- `ui/plugin/insert_menu` is how one gets there: it appends the id to
-- `more_tools` in both order modules, and being *in the order* is what makes
-- MenuSorter place an entry properly rather than sweep it up as an orphan --
-- and what lets a menu customiser, which reads those orders, see it at all.
-- Every contributed plugin on the device does this at load time, which is why
-- theirs appear where they should and ours did not.
--
-- Never both places at once: with our id in `more_tools` *and* in the row of
-- tabs, MenuSorter places the contents in whichever it finds first and leaves
-- an empty row behind in the other.
local function inMoreTools(order, present)
    local list = order and order.more_tools
    if type(list) ~= "table" then return end
    local at = positionIn(list)
    if present and not at then
        table.insert(list, MENU_TAB_ID)
    elseif at and not present then
        table.remove(list, at)
    end
end

--- Takes the tab back out of KOReader's menu row. The row is shared and lives
-- as long as KOReader does, so switching this off has to undo it.
local function removeMenuTab()
    local order = menuOrder()
    if not order then return end
    local at = tabRowPosition(order)
    if at then table.remove(order["KOMenu:menu_buttons"], at) end
    order[MENU_TAB_ID] = nil
    inMoreTools(order, true) -- back where a plugin belongs
end

--- Would a tab of ours survive the sort?
--
-- `mergeAndSort` copies the user's menu order file over the order *after* we
-- have had our say, so if that file names the row of tabs and we are not in it,
-- the tab cannot be there -- and claiming it costs us the entry under Tools as
-- well, which is the only place left. That file is the one thing that can be
-- read *before* the build, so read it.
-- The answer is kept (`self.tab_survives`) because it comes out of a file on
-- disk and `enabled_func` is re-read on every repaint of the menu: a `dofile`
-- per repaint is not what a Kindle should spend its time on. The file belongs
-- to another plugin, and changing it needs a restart to take effect anyway.
function Lardo:tabWouldSurvive()
    if self.tab_survives ~= nil then return self.tab_survives end
    local survives = true
    local path = self:menuOrderFile()
    if path then
        local ok, order = pcall(dofile, path)
        if ok and type(order) == "table" then
            local row = order["KOMenu:menu_buttons"]
            -- a file that says nothing about the row leaves ours alone
            if type(row) == "table" then survives = positionIn(row) ~= nil end
        end
    end
    self.tab_survives = survives
    return survives
end

--- Publishes our entries as a tab: one `menu_items` entry per top-level item,
-- because that is where MenuSorter takes a tab's contents from.
-- @return whether there is a tab now
function Lardo:installMenuTab(menu_items)
    local order = menuOrder()
    if not order or not self:tabWouldSurvive() then return false end

    local items = self:menuItemsToTouchMenu(self:getMenuItems())
    local ids = {}
    for i = 1, #items do
        local id = MENU_TAB_ID .. "_" .. i
        menu_items[id] = items[i]
        ids[i] = id
    end
    order[MENU_TAB_ID] = ids
    menu_items[MENU_TAB_ID] = {
        icon = MENU_TAB_ICON,
        text = _("Lardo"),
    }
    if not tabRowPosition(order) then
        -- at the end: inserting anywhere else would shift the indices KOReader
        -- remembers as "the tab you had open last"
        table.insert(order["KOMenu:menu_buttons"], MENU_TAB_ID)
    end
    inMoreTools(order, false) -- a tab *or* an entry, never both
    return true
end

--- KOReader asks each plugin for its entries inside a `pcall` of its own
-- (`pcall(widget.addToMainMenu, widget, self.menu_items)`, and on a failure it
-- logs "failed to register widget" and carries on). So anything that throws in
-- here does not crash KOReader: it takes Lardo out of KOReader's menu with
-- nothing on the screen to say why, which is a far quieter way to lose. One
-- entry that still opens the recipes beats the tidiest menu that is not there.
function Lardo:addToMainMenu(menu_items)
    -- before anything of ours is in it, and before the sorter eats it
    self:rememberMenuItems(menu_items)
    local ok, err = pcall(function() self:buildMenuEntry(menu_items) end)
    if not ok then
        logger.err("Lardo: the menu entry could not be built:", err)
        removeMenuTab() -- whatever we cannot build, we should not claim a tab for
        menu_items[MENU_TAB_ID] = {
            text = _("Lardo"),
            text_func = function() return _("Lardo") end,
            sorting_hint = "tools",
            sub_item_table = {
                {
                    text = _("Browse recipes"),
                    callback = function() self:showBrowser() end,
                },
            },
        }
    end
    -- its own pcall: "Start with" is KOReader's entry, not ours, and a failure
    -- there must not cost us the entry we just built
    local injected, inject_err = pcall(function() self:injectStartWith(menu_items) end)
    if not injected then
        logger.warn("Lardo: \"Start with\" could not be extended:", inject_err)
    end
end

function Lardo:buildMenuEntry(menu_items)
    -- Whether this build asked for a tab at all. Only then is a menu without
    -- one something to report: with the tab turned on but known to be
    -- impossible (see tabWouldSurvive) we never claimed one, and a menu that
    -- has not got what we did not ask for is not news.
    self.tab_claimed = false
    -- a tab belongs to the file manager's menu; the reader's is a different
    -- menu with a different order, and a recipe list is not a page in a book
    if self:usesOwnMenuTab() and not tab_refused and self.document == nil
            and self:installMenuTab(menu_items) then
        self.tab_claimed = true
        return
    end
    removeMenuTab()
    menu_items.lardo = {
        -- text_func is what gets drawn (Menu.getMenuText prefers it, so the
        -- entry follows a language change); text is for MenuSorter, which sorts
        -- and tags the top-level entries by their plain text.
        text = _("Lardo"),
        text_func = function() return _("Lardo") end,
        sorting_hint = "tools",
        sub_item_table = self:menuItemsToTouchMenu(self:getMenuItems()),
    }
end

--- Is Lardo anywhere in the menu KOReader has built?
--
-- `MenuSorter` writes an item's id into the table it builds for it, ours
-- included, wherever it ended up -- a tab of its own, Tools, More tools.
-- @param tabs `tab_item_table`: the tabs, each an array of the items in it
local function menuHasLardo(tabs, depth)
    depth = depth or 0
    tabs = tabs or {}
    for i = 1, #tabs do
        local entry = tabs[i]
        if type(entry) == "table" then
            if entry.id == MENU_TAB_ID then return true end
            -- Tools -> More tools -> Lardo is three, and a menu deeper than
            -- that is somebody else's problem
            if depth < 4 and menuHasLardo(entry.sub_item_table or entry, depth + 1) then
                return true
            end
        end
    end
    return false
end

--- The file a menu-customising plugin writes, if there is one.
--
-- `MenuSorter:mergeAndSort` reads it and copies it over the menu order, and
-- anything listed in its `KOMenu:disabled` is **deleted** from the flat table
-- before orphan handling -- so an id in there is gone from the menu with no
-- error and no trace. Our entry and our tab share the id `lardo`, so one line
-- in that file hides both, which is what "Lardo is in neither Tools nor More
-- tools, and the tab does nothing either" turned out to be.
function Lardo:menuOrderFile()
    local path = self.menu_order_file
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

--- Which tab of KOReader's menu is ours, if any. MenuSorter writes the id of a
-- tab into the table it builds for it, which is what this reads back.
function Lardo:menuTabIndex(menu)
    local tabs = menu and menu.tab_item_table
    if not tabs then return nil end
    for i = 1, #tabs do
        if tabs[i].id == MENU_TAB_ID then return i end
    end
    return nil
end

-- Labels: the value an entry shows, in the language it is shown in.
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

local function sortOrderLabel(order)
    for i = 1, #SORT_ORDERS do
        if SORT_ORDERS[i][1] == order then return _(SORT_ORDERS[i][2]) end
    end
    return order
end

--==========================================================================
-- The menu
--
-- There is one, and it is KOReader's own: the Menu button on either screen (and
-- the Menu key) opens it, and everything Lardo has is under Tools -> Lardo.
--
-- There was a menu of ours before, with the same entries in a dialog of its
-- own. It was a second menu to keep in step with the one every KOReader user
-- already knows, for settings that were never ours to keep twice. What is used
-- while cooking is on the button row instead, where it is one press.
--
-- An entry is KOReader's menu item (text, text_func, callback, enabled_func,
-- checked_func, help_text) plus two of ours: `sub_items`, a function returning
-- the level below, and `title` for what that level is called.
--==========================================================================

--- What a menu entry's callback is handed so it can have the menu redrawn once
-- it has changed something.
--
-- Our own entries call it (`on_change()`); the ones written for KOReader's menu
-- call `touchmenu_instance:updateItems()`. This answers to both -- and it has
-- to be given to *both* of them: handing KOReader's raw TouchMenu instance to
-- an entry that calls it is an attempt to call a table, which takes KOReader
-- down with it.
-- @param in_place true when the menu asking for it is still on screen behind
--   the callback (KOReader's own), false when the callback replaced it
local function refreshHandle(update, in_place)
    return setmetatable({ updateItems = function() update() end, in_place = in_place },
        { __call = function() update() end })
end

function Lardo:lastRefreshLabel()
    local time = self.cache:readSetting("list_time")
    return time and os.date("%Y-%m-%d %H:%M", time) or _("never")
end

--- Builds KOReader's menu if it has none built yet, which is what it does
-- itself on the first open. We do it a moment earlier only so that we can look
-- at the result -- which tab is ours -- before asking it to show itself.
local function ensureMenuBuilt(menu)
    if menu.tab_item_table ~= nil or not menu.setUpdateItemTable then return end
    local ok, err = pcall(function() menu:setUpdateItemTable() end)
    if not ok then
        logger.err("Lardo: KOReader's menu did not build:", err)
    end
end

--- The Menu button, on either screen, opens KOReader's own menu.
--
-- `FileManagerMenu:onShowMenu()` is public. We prefer our own UI's menu and
-- fall back to the file manager's, because a recipe opened from the reader has
-- a ReaderMenu that knows nothing about a list of recipes.
function Lardo:showKOReaderMenu()
    local menu = self.ui and self.ui.menu
    if not menu or not menu.onShowMenu then
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        menu = ok and FileManager and FileManager.instance and FileManager.instance.menu
    end
    if not (menu and menu.onShowMenu) then
        self:showError(_("This KOReader version does not open its menu on request."))
        return false
    end
    -- Never a rebuild for its own sake. KOReader builds its menu once and keeps
    -- it, and asking for another build on every press is what took it down when
    -- the Menu key was pressed on the list: `setUpdateItemTable` merges into
    -- `menu_items`, and `MenuSorter:sort` has eaten that table already -- it
    -- moves each item into its parent and *removes it* from the flat one
    -- ("remove reference from item_table so it won't show up as orphaned").
    --
    -- Nothing needs rebuilding anyway: TouchMenu re-reads `text_func`,
    -- `enabled_func` and `checked_func` every time it draws, which is why the
    -- entries that follow what is on screen are written that way.
    --
    -- Where a rebuild *is* the point -- a language change, the tab going on or
    -- off, the tab turning out not to be allowed -- it goes through
    -- `dropMenuCache`, which hands back the skeleton the sorter ate.
    ensureMenuBuilt(menu)
    -- The tab was asked for, the menu is built, and it is not in it: this
    -- KOReader's row of tabs is not ours to add to (see `tab_refused`). Give it
    -- up and build once more, which is the build that puts Lardo under Tools.
    if self.tab_claimed and not tab_refused
            and menu.tab_item_table and self:menuTabIndex(menu) == nil then
        local order = menuOrder()
        -- Worth knowing which it was: our id still in the order module means
        -- the row was overruled at sort time (a menu order file); our id gone
        -- from it means something took it out while KOReader was running.
        logger.warn("Lardo: the tab did not survive the sort; still in the order row:",
            tostring(order ~= nil and tabRowPosition(order) ~= nil))
        tab_refused = true
        self:dropMenuCache()
        ensureMenuBuilt(menu)
        -- Said, not just logged: a switch that can be turned on and then does
        -- nothing, with nothing on the screen about it, is the worst of the
        -- three. We know this happened -- we asked for the tab and the built
        -- menu has not got it -- so say that much, and name the file if there
        -- is one to name rather than guess at a culprit.
        local order_file = self:menuOrderFile()
        self:showError(order_file
            and T(_("Lardo's own tab could not be added to KOReader's menu.\n\nIts layout is fixed by:\n%1\n\nLardo is under Tools instead."),
                order_file)
            or _("Lardo's own tab could not be added to KOReader's menu: something else on this device decides how it is laid out.\n\nLardo is under Tools instead."))
    end
    -- Built, and Lardo is nowhere in it. Nothing failed -- an id in a menu
    -- order file's `KOMenu:disabled` is deleted before the sort even looks at
    -- it -- so without this the menu simply opens without us and there is no
    -- way left to reach a single setting. Said once, and only when that file is
    -- really there: otherwise it is a guess, and a guess is worse than silence.
    if menu.tab_item_table and not menuHasLardo(menu.tab_item_table) then
        local order_file = self:menuOrderFile()
        logger.warn("Lardo: KOReader's menu was built without Lardo in it; order file:",
            tostring(order_file))
        -- Only with the file in hand: without it we would be naming a cause we
        -- have not got, and a guess is worse than silence. The flag is on the
        -- *message*, so a file that turns up later is still reported once.
        if order_file and not menu_gap_reported then
            menu_gap_reported = true
            self:showError(T(_("Lardo is missing from KOReader's menu.\n\nA menu order file leaves it out:\n%1\n\nSwitch Lardo back on in the plugin that wrote it, or delete the file."),
                order_file))
        end
    end
    local ok, err = pcall(function() menu:onShowMenu(self:menuTabIndex(menu)) end)
    if not ok then
        logger.err("Lardo: KOReader's menu did not open:", err)
        self:showError(T(_("The menu could not be opened.\n\n%1"), tostring(err)))
        return false
    end
    return true
end



--- Mealie translates its answers from the Accept-Language header we send, and
-- the same setting picks the wording of the recipe chapters.
local function keepAwakeLabel(minutes)
    for i = 1, #KEEP_AWAKE_INTERVALS do
        if KEEP_AWAKE_INTERVALS[i][1] == minutes then
            return _(KEEP_AWAKE_INTERVALS[i][2])
        end
    end
    return tostring(minutes)
end

--- The menu, once: the doors in and out of Lardo, what is done to the list, and
-- the settings behind three categories.
--
-- The entries that only mean something with a screen of ours open are not left
-- out, they are disabled: `enabled_func` is re-read every time the menu is
-- drawn, so "Back to the list" is there and grey until there is a list to go
-- back to. A menu whose entries move around is harder to learn than one whose
-- entries grey out.
function Lardo:getMenuItems()
    local items = {}
    local function add(entry) table.insert(items, entry) end

    add({
        text_func = function() return _("Browse recipes") end,
        callback = function() self:showBrowser() end,
    })
    add({
        text_func = function() return _("Back to the list") end,
        enabled_func = function() return self.viewer ~= nil end,
        callback = function()
            if self.viewer then self.viewer:onClose() end
        end,
    })
    add({
        -- the way out: Back stays inside Lardo on purpose
        text_func = function() return _("Close Lardo") end,
        enabled_func = function() return self.browser ~= nil end,
        separator = true,
        callback = function()
            if self.browser then self.browser:onCloseAllMenus() end
        end,
    })

    add({
        text_func = function()
            local filter = self.filter
            return T(_("Filter: %1"), (filter and filter ~= "") and filter or _("none"))
        end,
        enabled_func = function() return self.browser ~= nil end,
        callback = function() self:startFiltering() end,
    })
    add({
        text_func = function() return _("Clear the filter") end,
        enabled_func = function() return self.filtering == true or self.filter ~= nil end,
        callback = function() self:clearFilter() end,
    })
    add({
        text_func = function() return T(_("Sort by: %1"), sortOrderLabel(self:getSortOrder())) end,
        title = _("Sort recipes by"),
        sub_items = function() return self:getSortMenuTable() end,
    })
    add({
        text_func = function() return T(_("Refresh (last: %1)"), self:lastRefreshLabel()) end,
        help_text = _("Fetches the list, and with it every recipe that is new or has changed, so everything is readable without WiFi afterwards."),
        separator = true,
        callback = function() self:refreshList() end,
    })

    add({
        text_func = function() return _("Screen") end,
        title = _("Screen"),
        sub_items = function() return self:getScreenMenuTable() end,
    })
    add({
        text_func = function() return _("Connection") end,
        title = _("Connection"),
        sub_items = function() return self:getConnectionMenuTable() end,
    })
    add({
        text_func = function() return _("Application settings") end,
        title = _("Application settings"),
        sub_items = function() return self:getApplicationMenuTable() end,
    })
    return items
end

--- KOReader's menu wants a table of items; ours wants the same items as a
-- dialog. This is the one place that knows both.
function Lardo:menuItemsToTouchMenu(items)
    local out = {}
    for i = 1, #items do
        local item = items[i]
        table.insert(out, {
            -- `text` as well as `text_func`: an entry with a label that never
            -- changes gives the plain one (the languages do), and dropping it
            -- here left KOReader's menu drawing rows with nothing on them.
            text = item.text,
            text_func = item.text_func,
            help_text = item.help_text,
            enabled_func = item.enabled_func,
            checked_func = item.checked_func,
            radio = item.radio,
            separator = item.separator,
            -- Closing is the default: an entry that takes you somewhere -- the
            -- filter box, a recipe, out of Lardo -- should leave the menu
            -- behind rather than sit under it. Entries that change a setting
            -- where it stands ask for `keep_menu_open` themselves.
            keep_menu_open = item.keep_menu_open == true,
            sub_item_table = item.sub_items and self:menuItemsToTouchMenu(item.sub_items()) or nil,
            callback = item.callback and function(touchmenu_instance)
                item.callback(refreshHandle(function()
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end, true))
            end or nil,
        })
    end
    return out
end

--- Everything about what is drawn and where.
function Lardo:getScreenMenuTable()
    return {
        {
            text_func = function()
                return T(_("Fonts: %1 pt, %2"), self:getFontSize(),
                    fontName(self.settings:readSetting("font_face")) or _("KOReader default"))
            end,
            title = _("Fonts"),
            sub_items = function() return self:getFontMenuTable() end,
        },
        {
            text_func = function()
                return T(_("Reading position bar: %1"),
                    progressPositionLabel(self:getProgressPosition()))
            end,
            title = _("Reading position bar"),
            sub_items = function() return self:getProgressMenuTable() end,
        },
        {
            text_func = function()
                return T(_("Keep the recipe on screen: %1"),
                    keepAwakeLabel(self:getKeepAwakeInterval()))
            end,
            help_text = _("A Kindle blanks the screen after ten minutes and has no setting for it. This tells it the recipe is still being read, and redraws the corner of the header while it is at it."),
            title = _("Keep the recipe on screen"),
            sub_items = function() return self:getKeepAwakeMenuTable() end,
        },
        {
            text_func = function() return _("Tags on the recipe list") end,
            help_text = _("Shows each recipe's tags in the right-hand column, before the time. The filter searches the tags either way."),
            checked_func = function() return self:showsTags() end,
            keep_menu_open = true,
            callback = function(on_change)
                self.settings:saveSetting("list_tags", not self:showsTags())
                self.settings:flush()
                self:updateBrowserItems() -- the list is behind the menu, already drawn
                if on_change then on_change() end
            end,
        },
        {
            text_func = function()
                return T(_("Status in the corner: %1"), self:statusItemsLabel())
            end,
            title = _("Status in the corner"),
            sub_items = function() return self:getStatusMenuTable() end,
        },
    }
end

--- Everything about the plugin rather than about a recipe.
function Lardo:getApplicationMenuTable()
    return {
        {
            text_func = function()
                return T(_("Language: %1"), LardoLang.nameFor(self:getLanguage()))
            end,
            title = _("Language"),
            sub_items = function() return self:getLanguageMenuTable() end,
        },
        {
            text_func = function()
                return T(N_("Offline: %1 recipe stored", "Offline: %1 recipes stored",
                    self:countCachedRecipes()), self:countCachedRecipes())
            end,
            title = _("Offline"),
            sub_items = function() return self:getOfflineMenuTable() end,
        },
        {
            text_func = function()
                local path = self:findShortcut()
                return T(_("Shortcut in the library: %1"), path or _("none"))
            end,
            help_text = _("Puts a file in the library that opens Lardo when it is tapped, for getting here without the menu."),
            title = _("Shortcut in the library"),
            sub_items = function() return self:getShortcutMenuTable() end,
        },
        {
            text_func = function() return _("Own tab in KOReader's menu") end,
            help_text = _("Puts Lardo in the menu's top row, with an icon of its own, and opens the menu straight into it. Off means one entry under Tools, the way plugins usually sit. A plugin that customises the menu can make the tab impossible; Lardo then stays under Tools."),
            -- Greyed where the row of tabs is fixed by a menu order file that
            -- does not name us: there the tab cannot be, and a switch that can
            -- be turned on and then does nothing is worse than one that says
            -- so. Only that one cause can be known in advance -- every other
            -- way of losing the tab is reported after the build instead.
            enabled_func = function() return self:tabWouldSurvive() end,
            checked_func = function() return self:usesOwnMenuTab() end,
            keep_menu_open = true,
            callback = function(on_change)
                self.settings:saveSetting("own_menu_tab", not self:usesOwnMenuTab())
                self.settings:flush()
                self:dropMenuCache() -- it has to be built again to move
                if on_change then on_change() end
            end,
        },
        {
            text_func = function() return _("Open Lardo instead of the file browser at start-up") end,
            checked_func = function()
                return G_reader_settings:readSetting("start_with") == START_WITH_VALUE
            end,
            keep_menu_open = true,
            callback = function(on_change)
                if G_reader_settings:readSetting("start_with") == START_WITH_VALUE then
                    G_reader_settings:saveSetting("start_with", "filemanager")
                else
                    G_reader_settings:saveSetting("start_with", START_WITH_VALUE)
                end
                if on_change then on_change() end
            end,
        },
    }
end

--- The fonts, in their own level: one size and one typeface for the recipes
-- and for the list, because they are read in the same kitchen light.
function Lardo:getFontMenuTable()
    return {
        {
            text_func = function() return T(_("Size: %1"), self:getFontSize()) end,
            help_text = _("Used for the recipes and for the recipe list."),
            keep_menu_open = true,
            callback = function(on_change) self:showFontSizeDialog(on_change) end,
        },
        {
            text_func = function()
                return T(_("Typeface: %1"),
                    fontName(self.settings:readSetting("font_face")) or _("KOReader default"))
            end,
            help_text = _("Used for the recipes and for the recipe list."),
            keep_menu_open = true,
            callback = function(on_change) self:showFontChooser(on_change) end,
        },
        {
            text_func = function() return _("Use KOReader's default typeface") end,
            enabled_func = function() return self.settings:readSetting("font_face") ~= nil end,
            keep_menu_open = true,
            callback = function(on_change)
                self:applyViewSetting("font_face", nil, "font_face")
                if on_change then on_change() end
            end,
        },
    }
end

--- One level down from "Sort by": the orders, ticked.
function Lardo:getSortMenuTable()
    local items = {}
    for i = 1, #SORT_ORDERS do
        local order, label = SORT_ORDERS[i][1], SORT_ORDERS[i][2]
        table.insert(items, {
            text_func = function() return _(label) end,
            checked_func = function() return self:getSortOrder() == order end,
            keep_menu_open = true,
            callback = function(on_change)
                self.settings:saveSetting("sort_by", order)
                self.settings:flush()
                self:updateBrowserItems()
                if on_change then on_change() end
            end,
        })
    end
    return items
end

--- One level down from "Reading position bar": where it can sit.
function Lardo:getProgressMenuTable()
    local items = {}
    for i = 1, #PROGRESS_POSITIONS do
        local position, label = PROGRESS_POSITIONS[i][1], PROGRESS_POSITIONS[i][2]
        table.insert(items, {
            text_func = function() return _(label) end,
            checked_func = function() return self:getProgressPosition() == position end,
            keep_menu_open = true,
            callback = function(on_change)
                self:applyViewSetting("progress_position", position, "progress_position")
                if on_change then on_change() end
            end,
        })
    end
    return items
end

--- One level down from "Keep the recipe on screen": how often to say so.
function Lardo:getKeepAwakeMenuTable()
    local items = {}
    for i = 1, #KEEP_AWAKE_INTERVALS do
        local minutes, label = KEEP_AWAKE_INTERVALS[i][1], KEEP_AWAKE_INTERVALS[i][2]
        table.insert(items, {
            text_func = function() return _(label) end,
            checked_func = function() return self:getKeepAwakeInterval() == minutes end,
            keep_menu_open = true,
            callback = function(on_change)
                local was_off = self:getKeepAwakeInterval() <= 0
                self.settings:saveSetting("keep_awake", minutes)
                self.settings:flush()
                self:stopKeepAwake()
                if self.viewer then self:startKeepAwake() end
                -- Switched on with nothing in the corner to show for it is a
                -- feature nobody can tell is working: the recipe simply stays
                -- on the screen, which is also what it does when this is off
                -- and you keep touching it. So the marker comes with it --
                -- once, when it is switched on; turning the marker off again
                -- and then changing the interval leaves that decision alone.
                if was_off and minutes > 0 then self:showStatusItem("awake") end
                if on_change then on_change() end
            end,
        })
    end
    return items
end

--- What the corner shows, in the order it shows it.
function Lardo:statusItemsLabel()
    local shown = self:getStatusItems()
    local definition = self:statusDefinition()
    local parts = {}
    for i = 1, #definition do
        if shown[definition[i][1]] then
            table.insert(parts, _(definition[i][2]))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or _("nothing")
end

--- One level down from "Status in the corner": a tick per thing it can show,
-- and the window that puts them in order.
function Lardo:getStatusMenuTable()
    local items = {}
    local definition = self:statusDefinition()
    for i = 1, #definition do
        local id, label = definition[i][1], definition[i][2]
        table.insert(items, {
            text_func = function() return _(label) end,
            checked_func = function() return self:getStatusItems()[id] == true end,
            separator = i == #definition,
            keep_menu_open = true,
            callback = function(on_change)
                self:toggleStatusItem(id)
                if on_change then on_change() end
            end,
        })
    end
    table.insert(items, {
        text_func = function() return _("Order…") end,
        help_text = _("Drag them into the order the corner draws them in."),
        enabled_func = function() return canArrange() end,
        keep_menu_open = true,
        callback = function(on_change) self:showStatusSortDialog(on_change) end,
    })
    return items
end

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
            text_func = function()
                local url = self.settings:readSetting("url")
                return T(_("Server address: %1"), (url and url ~= "") and url or _("not set"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:editServerUrl(touchmenu_instance) end,
        },
        {
            text_func = function() return _("Log in with username and password") end,
            keep_menu_open = true,
            callback = function() self:promptLogin() end,
        },
        {
            text_func = function()
                local token = self.settings:readSetting("token")
                -- the token itself is 200 characters of JWT; what is worth
                -- showing is whether there is one
                return T(_("API token: %1"), (token and token ~= "") and _("set") or _("none"))
            end,
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

--- Whether the rows carry their tags. On by default: on a list of three hundred
-- recipes, "obiad" next to the name is most of what tells them apart. Off for
-- anyone whose Mealie tags everything six ways, where the column would take the
-- room the names need.
function Lardo:showsTags()
    return self.settings:readSetting("list_tags") ~= false
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

    -- name, description and tags in one string: one find() per recipe per
    -- keystroke. Tags are in there whether or not they are shown on the rows --
    -- "zupa" should find the soups, and what the column has room for is a
    -- question about the width of the screen, not about what you meant.
    local haystacks = {}
    for i = 1, #sorted do
        local recipe = sorted[i]
        local parts = { lower(recipe) }
        if recipe.description ~= "" then
            parts[#parts + 1] = util.stringLower(recipe.description)
        end
        local tags = recipe.tags or {}
        if #tags > 0 then
            parts[#parts + 1] = util.stringLower(table.concat(tags, ", "))
        end
        haystacks[i] = #parts > 1 and table.concat(parts, "\n") or parts[1]
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
                mandatory = Recipe.listColumn(recipe, self:showsTags()),
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
        -- the trailing "_" is the cursor: it belongs there while something is
        -- being typed, and nowhere else. Once the keyboard is away the line is
        -- simply what the list is filtered by.
        title = self.filtering
            and T(_("Filter: %1_   %2/%3"), self.filter or "", #items, #self.list)
            or T(_("Filter: %1   %2/%3"), self.filter or "", #items, #self.list)
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
    if Device:hasKeyboard() then
        -- the line of chrome is the box already, and the letters go into it
        self.filtering = true
        self:updateBrowserItems()
        return
    end
    -- Without keys it is the same box, made real, in the same line -- with the
    -- keyboard under it and the list narrowing on every letter. It used to be a
    -- dialog in the middle of the screen that filtered only once confirmed,
    -- which is a different thing wearing the same word.
    if self.browser and self.browser.showFilterField then
        self.filtering = true
        local shown = self.browser:showFilterField(self.filter or "", function(text)
            self.filter = (text ~= "") and text or nil
            self:updateBrowserItems()
        end, function()
            -- the keyboard is away: nothing is being typed any more, and the
            -- line goes back to saying what the list is filtered by
            self.filtering = false
            self:updateBrowserItems()
        end)
        if shown then return end
        self.filtering = false
    end
    self:promptSearch() -- no list on screen, or a KOReader that would not have it
end

--- @return boolean whether there was a filter to clear
function Lardo:clearFilter()
    if self.browser then self.browser:closeFilterField() end
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
        menu_button_callback = function() self:showKOReaderMenu() end,
        search_button_callback = function() self:startFiltering() end,
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
            -- that is where the radio gets hung up, so it is where the corner
            -- of an open recipe stops being true
            self:refreshStatus()
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

--- A definition ({id, label} pairs) in the order it was arranged into: that
-- order first, then anything not in it -- something added by a later version
-- appears for everybody rather than only for people who never arranged theirs.
local function inSavedOrder(definition, order)
    if type(order) ~= "table" then return definition end
    local by_id, ordered, taken = {}, {}, {}
    for i = 1, #definition do by_id[definition[i][1]] = definition[i] end
    for i = 1, #order do
        local entry = by_id[order[i]]
        if entry and not taken[order[i]] then
            taken[order[i]] = true
            table.insert(ordered, entry)
        end
    end
    for i = 1, #definition do
        if not taken[definition[i][1]] then table.insert(ordered, definition[i]) end
    end
    return ordered
end

function Lardo:getProgressPosition()
    return self.settings:readSetting("progress_position") or DEFAULT_PROGRESS_POSITION
end

--==========================================================================
-- A "book" in the library that opens Lardo
--
-- KOReader has a mechanism for exactly this: an *auxiliary provider* -- a
-- plugin that opens a file instead of a document engine (the text editor and
-- the archive viewer are the two in KOReader itself). FileManager:openFile()
-- asks DocumentRegistry which provider a file belongs to and, for an auxiliary
-- one, calls `self[provider]:openFile(file)` -- `self` being the file manager
-- and `provider` our plugin's name, which is how a tap on a file reaches us.
--
-- So the shortcut is a real file with nothing in it that matters, and a file
-- type that is ours.
--
-- **The type is what makes it visible**, and this took a working shortcut that
-- nobody could see to work out. The file browser's filter is
-- `file_filter = function(filename) return DocumentRegistry:hasProvider(filename) end`
-- -- a *bare name*, not a path. Of the three things `hasProvider` accepts, only
-- the first can answer a bare name:
--
-- 1. `filetype_provider[suffix]`, set by `addProvider(extension, ...)`;
-- 2. an association by file type, which is skipped for an auxiliary provider
--    (`if provider and (not provider.order or include_aux)`, and `order` is
--    precisely what makes a provider auxiliary);
-- 3. an association for that one file, which lives in its sidecar -- and a bare
--    filename cannot be resolved to one.
--
-- `addAuxProvider` alone, which is what we did, sets none of them: it says who
-- we are, not what we own. Registering the extension as well sets (1), and the
-- registry is safe to put an auxiliary provider in -- `getFallbackProvider`
-- only ever returns the `txt` one, so we cannot become the opener of last
-- resort, and `openDocument` pcalls `provider.new`, so a cover browser asking
-- our file for a thumbnail gets a warning in the log rather than a crash.
--==========================================================================

local SHORTCUT_SUFFIX = ".lardo"
-- Not translated, and not "Recipes": on a Kindle this sits among the books, and
-- the plugin it opens is called Lardo in every language.
local SHORTCUT_NAME = "Lardo"

-- The key FileManager looks us up by: it does `self[provider]:openFile(file)`,
-- and `self[...]` was set from the plugin's name in _meta.lua. It cannot be read
-- off `self.name`, which is only the plugin's name until it is registered:
-- `FileManager:registerModule` then overwrites it with "filemanager" .. name (and
-- ReaderUI does the same with "reader"), so by the time a menu entry is pressed,
-- self.name is "filemanagerlardo" and the registry knows nothing about it.
local PROVIDER_KEY = "lardo"

-- The registry is a module and lives as long as KOReader does, while the plugin
-- is instantiated again for every book opened and closed. Registering twice
-- would append to `DocumentRegistry.providers` for the whole session.
local provider_registered = false

function Lardo:registerProvider()
    if provider_registered or not DocumentRegistry.addAuxProvider then return end
    local provider = {
        provider_name = self.fullname or _("Lardo"),
        provider = PROVIDER_KEY,
        order = 40, -- what makes it auxiliary, and where it sits in "Open with…"
        disable_file = false, -- "always use for this file" is the whole point
        disable_type = false,
    }
    DocumentRegistry:addAuxProvider(provider) -- who we are
    if DocumentRegistry.addProvider then
        -- ...and what we own, which is the half that makes the file visible
        DocumentRegistry:addProvider(SHORTCUT_SUFFIX:sub(2), "application/x-lardo",
            provider, 100)
    end
    provider_registered = true
end

--- Asked by the "Open with…" dialog before offering us for a file.
function Lardo:isFileTypeSupported(file)
    return type(file) == "string"
        and file:lower():sub(-#SHORTCUT_SUFFIX) == SHORTCUT_SUFFIX
end

--- What a tap on the shortcut does. The file itself is not read: it is a door.
function Lardo:openFile(_file) -- luacheck: ignore
    self:showBrowser()
end

--- Where the shortcut goes: wherever it was pointed at, else the folder being
-- browsed, else KOReader's home.
function Lardo:shortcutDir()
    local chosen = self.settings:readSetting("shortcut_dir")
    if chosen and chosen ~= "" then return chosen end
    local chooser = self.ui and self.ui.file_chooser
    if chooser and chooser.path and chooser.path ~= "" then return chooser.path end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home and home ~= "" then return home end
    return Device.home_dir or DataStorage:getDataDir()
end

function Lardo:shortcutPath()
    return self:shortcutDir() .. "/" .. SHORTCUT_NAME .. SHORTCUT_SUFFIX
end

--- @return the path of the shortcut, if there is one
function Lardo:findShortcut()
    local path = self:shortcutPath()
    if lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

--- Points it at another folder, and takes the shortcut with it if there is one.
function Lardo:chooseShortcutDir(on_change)
    local PathChooser = optionalWidget("ui/widget/pathchooser")
    if not PathChooser then
        self:showError(_("This KOReader version has no folder picker."))
        return
    end
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        path = self:shortcutDir(),
        onConfirm = function(new_path)
            if not new_path or new_path == "" then return end
            local had_one = self:findShortcut()
            if had_one then self:removeShortcut(true) end
            self.settings:saveSetting("shortcut_dir", new_path)
            self.settings:flush()
            if had_one then
                self:createShortcut() -- follow it, rather than leave it behind
            end
            if on_change then on_change() end
        end,
    })
end

--- Writes the shortcut and tells KOReader that it is ours to open, which is
-- both what a tap on it does and what makes the file browser show it at all.
function Lardo:createShortcut()
    local path = self:shortcutPath()
    local file, err = io.open(path, "w")
    if not file then
        logger.warn("Lardo: could not write", path, err)
        self:showError(T(_("Could not write the shortcut:\n%1"), path))
        return nil
    end
    file:write(_("Opening this in KOReader opens Lardo.\n"))
    file:close()

    -- No association is written into the file's sidecar: the *type* is ours, so
    -- the browser lists it and a tap on it reaches us without one. Earlier
    -- versions wrote one, which is why removing a shortcut still purges it.
    -- the folder on screen was listed before the file existed
    if self.ui and self.ui.onRefresh then
        pcall(function() self.ui:onRefresh() end)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Added to the library:\n%1\n\nOpening it opens Lardo."), path),
    })
    return path
end

--- @param quietly true when it is being moved rather than thrown away
function Lardo:removeShortcut(quietly)
    local path = self:findShortcut()
    if not path then return end
    os.remove(path)
    -- the sidecar is what made the file visible; it has nothing left to describe
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.open then
        pcall(function() DocSettings:open(path):purge() end)
    end
    if self.ui and self.ui.onRefresh then
        pcall(function() self.ui:onRefresh() end)
    end
    if not quietly then
        UIManager:show(InfoMessage:new{
            text = T(_("Removed from the library:\n%1"), path),
            timeout = 3,
        })
    end
end

--- The shortcut: where it goes, and whether there is one.
function Lardo:getShortcutMenuTable()
    return {
        {
            text_func = function() return T(_("Folder: %1"), self:shortcutDir()) end,
            keep_menu_open = true,
            callback = function(on_change) self:chooseShortcutDir(on_change) end,
        },
        {
            text_func = function() return _("Put the shortcut there") end,
            enabled_func = function() return self:findShortcut() == nil end,
            keep_menu_open = true,
            callback = function(on_change)
                self:createShortcut()
                if on_change then on_change() end
            end,
        },
        {
            text_func = function() return _("Remove the shortcut") end,
            enabled_func = function() return self:findShortcut() ~= nil end,
            keep_menu_open = true,
            callback = function(on_change)
                self:removeShortcut()
                if on_change then on_change() end
            end,
        },
    }
end

--==========================================================================
-- Keeping the recipe on screen
--
-- A Kindle's screensaver is the framework's, not KOReader's: powerd's "t1"
-- timer fires ten minutes after the last thing it counts as activity, and
-- there is no setting for it on the device. KOReader grabs input straight from
-- the event devices, so as far as powerd is concerned a recipe being read is a
-- device nobody has touched.
--
-- What it does understand is being told to start counting again, which is what
-- KindlePowerD:resetT1Timeout() does (it sets com.lab126.powerd's
-- touchScreenSaverTimeout through lipc). So: while a recipe is open, say so
-- every few minutes. Nothing is left switched on behind us -- stop saying it,
-- and ten minutes later the Kindle does what it always did. That is the whole
-- reason this is a repeating nudge rather than
-- `lipc-set-prop com.lab126.powerd preventScreenSaver 1`, which is a flag you
-- can leave a device stuck with if KOReader goes away without clearing it.
--==========================================================================

--- @return minutes between nudges, or 0 when the recipe is left to fall asleep
function Lardo:getKeepAwakeInterval()
    local stored = self.settings:readSetting("keep_awake")
    for i = 1, #KEEP_AWAKE_INTERVALS do
        if KEEP_AWAKE_INTERVALS[i][1] == stored then return stored end
    end
    return DEFAULT_KEEP_AWAKE
end

--- Whether the screen is actually being kept on right now -- which is not the
-- same as the setting being on: while charging we leave the device alone, and
-- then saying so in the corner would be a lie.
function Lardo:isKeepingAwake()
    if self:getKeepAwakeInterval() <= 0 then return false end
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    -- KOReader's own AutoSuspend skips the reset while charging, where it
    -- causes problems; a charging device is not about to run its battery down.
    local charging = powerd and powerd.isCharging and powerd:isCharging()
        and not (powerd.isCharged and powerd:isCharged())
    return not charging
end

--- Tells the device the recipe is still being read, and redraws the header so
-- that what it says about the battery and the time is true.
function Lardo:keepAwakeTick()
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    if powerd and powerd.resetT1Timeout and self:isKeepingAwake() then
        local ok, err = pcall(function() powerd:resetT1Timeout() end)
        if not ok then
            logger.warn("Lardo: could not reset the screensaver timer:", err)
        end
    end
    -- The corner is the visible half, and it is on the interval that was asked
    -- for: an e-ink refresh every four minutes to move a clock by four minutes
    -- is more flicker than anybody wants.
    local due = self:getKeepAwakeInterval() * 60 - 30
    local now = os.time()
    if not self.status_drawn_at or now - self.status_drawn_at >= due then
        self.status_drawn_at = now
        self:refreshStatus()
    end
    self:scheduleKeepAwake()
end

function Lardo:scheduleKeepAwake()
    local minutes = self:getKeepAwakeInterval()
    if minutes <= 0 or not self.viewer then return end
    self.keep_awake_task = self.keep_awake_task or function() self:keepAwakeTick() end
    UIManager:unschedule(self.keep_awake_task)
    -- Never further apart than the device allows, and never further apart than
    -- what was asked for either -- picking "every 5 minutes" should not mean a
    -- corner that is redrawn less often than that.
    local seconds = math.min(KEEP_AWAKE_POKE_SECONDS, math.max(minutes * 60 - 30, 60))
    UIManager:scheduleIn(seconds, self.keep_awake_task)
end

function Lardo:startKeepAwake()
    if self:getKeepAwakeInterval() <= 0 then return end
    self.status_drawn_at = nil -- the first tick draws it
    -- KOReader's own auto-suspend is a separate clock from the framework's, and
    -- would put the device to sleep with the recipe on screen; this is the flag
    -- its plugins use to say "not now" (autoturn.koplugin does the same).
    PluginShare.pause_auto_suspend = true
    self:keepAwakeTick() -- once now, so a stale battery reading is not the first thing you see
end

function Lardo:stopKeepAwake()
    if self.keep_awake_task then
        UIManager:unschedule(self.keep_awake_task)
    end
    PluginShare.pause_auto_suspend = false
end

--- What the corner can show, in the order it was arranged into.
function Lardo:statusDefinition()
    return inSavedOrder(STATUS_ITEMS, self.settings:readSetting("status_order"))
end

--- One item of it, or nil when the device has nothing to say about it.
function Lardo:statusPart(id)
    if id == "awake" then
        if not self:isKeepingAwake() then return nil end
        -- One letter: the corner is next to the recipe's cooking time, and a
        -- word there reads as part of it. "A" for awake, and whatever letter
        -- the language it is read in would use (see lardoi18n.lua).
        return _("A")
    elseif id == "battery" then
        if not (Device.hasBattery and Device:hasBattery()) then return nil end
        local powerd = Device.getPowerDevice and Device:getPowerDevice()
        local capacity = powerd and powerd.getCapacity and powerd:getCapacity()
        if not capacity then return nil end
        local charging = powerd.isCharging and powerd:isCharging()
        return (charging and "+" or "") .. capacity .. "%"
    elseif id == "clock" then
        return os.date("%H:%M")
    elseif id == "wifi" then
        if NetworkMgr.isWifiOn and NetworkMgr:isWifiOn() then return _("WiFi") end
        return nil
    end
    return nil
end

--- The right hand corner of a recipe: whatever of the device's own state has
-- been asked for, in the order it was asked for.
--
-- Plain text rather than KOReader's battery glyphs, which come from an icon
-- font a Kindle Keyboard may not have in its fallbacks -- a percentage nobody
-- can misread beats a box where a symbol should be.
function Lardo:statusText()
    local shown = self:getStatusItems()
    local definition = self:statusDefinition()
    local parts = {}
    for i = 1, #definition do
        local id = definition[i][1]
        if shown[id] then
            local part = self:statusPart(id)
            if part then table.insert(parts, part) end
        end
    end
    return table.concat(parts, "  ")
end

--- @return a set keyed by status item id
function Lardo:getStatusItems()
    local stored = self.settings:readSetting("status_items")
    local shown = {}
    for i = 1, #STATUS_ITEMS do
        local id = STATUS_ITEMS[i][1]
        if stored then
            shown[id] = stored[id] == true
        else
            -- what a cook wants to know unasked: how much battery is left, and
            -- whether the screen is going to stay on
            shown[id] = id == "battery" or id == "awake"
        end
    end
    return shown
end

--- Redraws the corner of an open recipe. Cheap when nothing changed: the view
-- compares the text before it rebuilds anything.
function Lardo:refreshStatus()
    if self.viewer and self.viewer.setStatus then
        self.viewer:setStatus(self:statusText())
    end
end

--- KOReader broadcasts these when the radio goes up or down (it is what its own
-- status bar listens to). The corner says whether WiFi is on, and "at the next
-- tick, in up to ten minutes" is not an answer when the answer is on screen --
-- a refresh that hangs the radio up afterwards left the mark sitting there.
function Lardo:onNetworkConnected()
    self:refreshStatus()
end
Lardo.onNetworkDisconnected = Lardo.onNetworkConnected

function Lardo:saveStatusItems(order, enabled)
    self.settings:saveSetting("status_order", order)
    self.settings:saveSetting("status_items", enabled)
    self.settings:flush()
    self:refreshStatus()
end

--- Switches one corner item on, leaving the others as they are.
function Lardo:showStatusItem(id)
    local shown = self:getStatusItems()
    if shown[id] then return end
    shown[id] = true
    self.settings:saveSetting("status_items", shown)
    self.settings:flush()
    self:refreshStatus()
end

function Lardo:toggleStatusItem(id)
    local shown = self:getStatusItems()
    shown[id] = not shown[id]
    self.settings:saveSetting("status_items", shown)
    self.settings:flush()
    self:refreshStatus()
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
            status_text = self:statusText(),
            next_recipe_callback = (count > 1) and function()
                self:showRecipeAt(index < count and index + 1 or 1)
            end or nil,
            prev_recipe_callback = (count > 1) and function()
                self:showRecipeAt(index > 1 and index - 1 or count)
            end or nil,
            menu_callback = function() self:showKOReaderMenu() end,
            close_callback = function()
                if self.viewer == viewer then
                    self.viewer = nil
                    -- and the device goes back to falling asleep on its own
                    self:stopKeepAwake()
                    -- back on the list: the recipe's text can go, it is on the
                    -- device and the next open reads it again
                    self.current_recipe = nil
                end
            end,
        }
        self.viewer = viewer
        UIManager:show(viewer)
        self:startKeepAwake()
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

--- A - 20 A +, for a KOReader whose number picker we cannot use. The number in
-- the middle is updated in place, so the dialog does not have to be closed and
-- reopened on every step.
function Lardo:showFontSizeSteps(on_change)
    local dialog
    local function step(delta)
        self:changeFontSize(delta)
        local button = dialog and dialog.getButtonById and dialog:getButtonById(FONT_SIZE_BUTTON_ID)
        if button and button.setText then
            button:setText(tostring(self:getFontSize()), button.width)
            UIManager:setDirty(dialog, "ui")
        end
        if on_change then on_change() end
    end
    dialog = ButtonDialog:new{
        title = _("Font size"),
        buttons = {{
            { text = "A -", callback = function() step(-1) end },
            { id = FONT_SIZE_BUTTON_ID, text = tostring(self:getFontSize()) },
            { text = "A +", callback = function() step(1) end },
        }},
    }
    UIManager:show(dialog)
    return dialog
end

function Lardo:changeFontSize(delta)
    local size = self:getFontSize() + delta
    if size < 12 then size = 12 elseif size > 40 then size = 40 end
    self:applyViewSetting("font_size", size, "font_size")
end

function Lardo:showFontSizeDialog(on_change)
    local SpinWidget = optionalWidget("ui/widget/spinwidget")
    if not SpinWidget then
        -- A KOReader without a number picker used to be told to use the A- / A+
        -- buttons in the recipe menu. There is no such row any more (every menu
        -- entry is its value, and opens what can be changed), so the stepping
        -- lives here instead -- the one place the size is changed at all.
        self:showFontSizeSteps(on_change)
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

--- What a refresh still has to fetch after the index: only recipes that are
-- missing or whose updatedAt moved, so one list request is enough to know --
-- and the stamps mean not one stored recipe has to be opened to work it out.
--- One window for putting things in order: drag them where you want them.
--
-- KOReader's SortWidget can carry a checkbox per line as well, and it used to
-- carry ours -- but that checkbox is the *only* part of a line that toggles: a
-- tap anywhere else picks the line up to move it. On a 600 px screen that is a
-- small square to hit and a surprising thing to miss, and what it looks like is
-- "it will not switch on". So this window does one job, and what is switched on
-- is ticked in the menu, where the tick is the whole line.
--
-- @param spec title, definition ({id, English label} pairs, in order), save(order)
function Lardo:showArrangeDialog(spec, on_change)
    local SortWidget = optionalWidget("ui/widget/sortwidget")
    if not SortWidget then
        self:showError(_("This KOReader version cannot reorder them."))
        return
    end

    local items = {}
    for i = 1, #spec.definition do
        items[i] = { text = _(spec.definition[i][2]), label = spec.definition[i][1] }
    end

    UIManager:show(SortWidget:new{
        title = spec.title,
        item_table = items,
        callback = function()
            -- SortWidget has reordered item_table in place by the time it calls us
            local order = {}
            for i = 1, #items do order[i] = items[i].label end
            spec.save(order)
            -- Only a menu still on screen behind this window wants redrawing;
            -- reopening the one we replaced would land it on top.
            if on_change and on_change.in_place then on_change() end
        end,
    })
end

--- What the corner of a recipe's header shows, and in which order.
function Lardo:showStatusSortDialog(on_change)
    return self:showArrangeDialog({
        title = _("Status in the corner"),
        definition = self:statusDefinition(),
        save = function(order)
            self:saveStatusItems(order, self.settings:readSetting("status_items"))
        end,
    }, on_change)
end

--- A list of entries as a dialog, for the two places that are not the menu:
-- the Sort button on the row, and anything else that has to ask a short
-- question. A tick is KOReader's own `checked_func`, redrawn where it stands.
-- @param go_back what Back should do here: the level above, or nothing
function Lardo:showMenuDialog(title, items, go_back)
    local dialog
    local function reopen() self:showMenuDialog(title, items, go_back) end
    local reopen_handle = refreshHandle(reopen, false)

    local ticks = {}
    local function redrawTicks()
        for i = 1, #ticks do
            local button = dialog and dialog.getButtonById and dialog:getButtonById(ticks[i])
            if button and button.setText and button.getDisplayText then
                button:setText(button:getDisplayText(), button.width)
            end
        end
        if dialog then UIManager:setDirty(dialog, "ui") end
    end
    local in_place_handle = refreshHandle(redrawTicks, true)

    local buttons = {}
    for i = 1, #items do
        local item = items[i]
        local label = item.text_func and item.text_func() or item.text
        if label then
            local id = item.checked_func and ("lardo_tick_" .. i) or nil
            if id then ticks[#ticks + 1] = id end
            local usable = (item.callback ~= nil or item.sub_items ~= nil)
                and (not item.enabled_func or item.enabled_func())
            table.insert(buttons, {{
                id = id,
                text = label,
                checked_func = item.checked_func,
                enabled = usable,
                callback = function()
                    if item.sub_items then
                        UIManager:close(dialog)
                        self:showMenuDialog(item.title or label, item.sub_items(), reopen)
                        return
                    end
                    if not item.callback then return end
                    if item.checked_func then
                        -- stays open: you are picking from a list, and the list
                        -- is what you want to see afterwards
                        item.callback(in_place_handle)
                        redrawTicks()
                    else
                        UIManager:close(dialog)
                        item.callback(reopen_handle)
                    end
                end,
            }})
        end
    end
    dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
        -- Back, and a tap outside, come through here; a button that closes the
        -- dialog itself does not, which is what keeps picking a value from
        -- counting as going back.
        tap_close_callback = go_back,
    }
    UIManager:show(dialog)
    return dialog
end

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
