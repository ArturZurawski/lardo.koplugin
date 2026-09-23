-- Run with: tests/run.sh  (needs any Lua 5.1 / LuaJIT interpreter)
local here = (arg[0] or "tests/x"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/stub/?.lua;" .. here .. "/../lardo.koplugin/?.lua;" .. package.path

local failures, checks = 0, 0
local function check(cond, label, extra)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. label)
        if extra then print("      " .. tostring(extra)) end
    end
end

-- KOReader globals
G_reader_settings = require("luasettings"):open("global")

-- Socket stack stubs (shared with the API test)
local last_request
local next_responses = {}
local request_count = 0
-- Every refresh also asks who we are and what we starred. Those two are
-- answered out of band, so the queued responses stay about recipes and the
-- request counts stay readable.
local favorite_ids = {}
local user_request_count = 0
package.loaded["socket.http"] = {
    request = function(req)
        last_request = req
        if req.url:find("/api/users/", 1, true) then
            user_request_count = user_request_count + 1
            local body = '{id="u1"}'
            if req.url:find("/favorites", 1, true) then
                local parts = {}
                for i = 1, #favorite_ids do
                    parts[i] = string.format('{recipeId="%s",isFavorite=true}', favorite_ids[i])
                end
                body = "{ratings={" .. table.concat(parts, ",") .. "}}"
            end
            req.sink(body)
            return 1, 200, {}, "200"
        end
        request_count = request_count + 1
        local response = table.remove(next_responses, 1) or { code = 200, body = "{}" }
        if response.body then req.sink(response.body) end
        return 1, response.code, {}, response.status or tostring(response.code)
    end,
}
package.loaded["socket"] = {
    skip = function(n, ...)
        local vals = { ... }
        local out = {}
        for i = n + 1, #vals do out[#out + 1] = vals[i] end
        return unpack(out)
    end,
}
package.loaded["ltn12"] = {
    sink = { table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end },
    source = { string = function(s) return s end },
}
package.loaded["socketutil"] = {
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    set_timeout = function() end, reset_timeout = function() end,
}
package.loaded["json"] = { decode = function(str) return assert(loadstring("return " .. str))() end }

local UIManager = require("ui/uimanager")
local Lardo = require("main")

-- Config files the plugin should pick up; koreader/settings is the default
-- location, /mnt/us (the home directory stub) is one of the fallbacks.
local test_dir = assert(os.getenv("MEALIE_TEST_DIR"), "run the suite through tests/run.sh")
local conf_path = test_dir .. "/koreader/settings/lardo.conf"
local fallback_conf_path = test_dir .. "/lardo.conf"
local function writeConf(text, path)
    local f = assert(io.open(path or conf_path, "w"))
    f:write(text)
    f:close()
end
os.remove(conf_path)
os.remove(fallback_conf_path)

-- Recipes are one file each, and here they go into the temporary tree rather
-- than into the settings directory the device would use.
Lardo.recipes_dir = test_dir .. "/koreader/settings/lardo_recipes"

--== init without a config file ============================================
local plugin = Lardo:new{}
check(plugin.settings ~= nil, "settings opened on init")
check(plugin:isConfigured() == false, "not configured without url")
check(require("dispatcher").actions["lardo_recipes"] ~= nil, "dispatcher action registered")

--== configuration file import =============================================
writeConf("url = http://mealie.lan:9000\ntoken = tok-abc\nusername=u\npassword=p\n")
plugin = Lardo:new{}
check(plugin:isConfigured(), "url imported from the config file")
check(plugin.settings:readSetting("token") == "tok-abc", "token imported from the config file")
check(plugin.conf_credentials ~= nil and plugin.conf_credentials.username == "u",
    "credentials kept in memory")
check(plugin.settings:readSetting("conf_signature") ~= nil, "import signature stored")

-- unchanged file is not re-imported over a value edited in the UI
plugin.settings:saveSetting("url", "http://edited.lan")
local imported = plugin:importConfigFile(false)
check(imported == false, "unchanged config file is not re-imported")
check(plugin.settings:readSetting("url") == "http://edited.lan", "UI edit survives")

-- a changed file wins again
writeConf("url = http://mealie.lan:9001\ntoken = tok-xyz\n")
imported = plugin:importConfigFile(false)
check(imported == true, "changed config file is re-imported")
check(plugin.settings:readSetting("url") == "http://mealie.lan:9001", "url updated from file")
check(plugin.conf_credentials == nil, "credentials cleared when removed from the file")

-- a file in one of the fallback locations is imported just the same
os.remove(conf_path)
writeConf("url = http://fallback.lan\ntoken = tok-fallback\n", fallback_conf_path)
local fallback_plugin = Lardo:new{}
check(fallback_plugin.settings:readSetting("url") == "http://fallback.lan",
    "config file outside koreader/settings is imported",
    fallback_plugin.settings:readSetting("url"))
check(fallback_plugin.settings:readSetting("token") == "tok-fallback", "token imported from the fallback")
os.remove(fallback_conf_path)

-- edits made over USB while KOReader is running are picked up on their own
writeConf("url = http://mealie.lan:9000\ntoken = tok-abc\n")
plugin = Lardo:new{}
writeConf("url = http://changed-over-usb.lan\ntoken = tok-usb\n")
check(plugin.settings:readSetting("url") == "http://mealie.lan:9000", "still on the old value")
plugin:showBrowser()
check(plugin.settings:readSetting("url") == "http://changed-over-usb.lan",
    "opening the list re-reads a changed lardo.conf",
    plugin.settings:readSetting("url"))
check(plugin.settings:readSetting("token") == "tok-usb", "and the new token")
plugin.browser:onCloseAllMenus()
UIManager.ticks = {} -- showBrowser() queues a first refresh; not our subject here
os.remove(conf_path)

--== start_with integration ================================================
local function fakeStartWithItem()
    return {
        text_func = function() return "Start with: file browser" end,
        sub_item_table = {
            { text = "file browser" },
            { text = "history" },
        },
    }
end

local menu_items = { start_with = fakeStartWithItem() }
plugin:addToMainMenu(menu_items)
check(menu_items.lardo ~= nil, "plugin menu entry added")
check(menu_items.lardo.sorting_hint == "tools", "menu entry sorted into Tools")
check(#menu_items.start_with.sub_item_table == 3, "start_with option injected",
    #menu_items.start_with.sub_item_table)
local injected = menu_items.start_with.sub_item_table[3]
check(injected.radio == true, "injected option is a radio button")
check(injected.checked_func() == false, "not checked by default")
check(menu_items.start_with.text_func() == "Start with: file browser", "core label untouched by default")
injected.callback()
check(G_reader_settings:readSetting("start_with") == "lardo", "selecting the option stores the setting")
check(injected.checked_func() == true, "checked once selected")
check(menu_items.start_with.text_func() == "Start with: Lardo", "label reflects our choice")

-- the reader menu has no start_with entry; must not blow up
local reader_items = {}
plugin:addToMainMenu(reader_items)
check(reader_items.lardo ~= nil, "menu entry also added without start_with")

-- the toggle in our own menu flips back to the file browser
local function findItem(sub_item_table, label)
    for i = 1, #sub_item_table do
        local item = sub_item_table[i]
        local text = item.text or (item.text_func and item.text_func())
        if text == label then return item end
    end
end
-- it lives a level down now, under the settings that are set once
local function findItemDeep(sub_item_table, label)
    local item = findItem(sub_item_table, label)
    if item then return item end
    for i = 1, #sub_item_table do
        if sub_item_table[i].sub_item_table then
            local found = findItemDeep(sub_item_table[i].sub_item_table, label)
            if found then return found end
        end
    end
end
local toggle = findItemDeep(menu_items.lardo.sub_item_table,
    "Open Lardo instead of the file browser at start-up")
check(toggle ~= nil, "start-up toggle present in our menu")
check(toggle.checked_func() == true, "start-up toggle reflects the setting")
toggle.callback()
check(G_reader_settings:readSetting("start_with") == "filemanager", "toggle turns it back off")

--== start-up takeover =====================================================
G_reader_settings:saveSetting("start_with", "lardo")
local fm_plugin = Lardo:new{ ui = {} }           -- file manager: no document
check(#UIManager.ticks == 1, "browser scheduled at start-up", #UIManager.ticks)
UIManager.ticks = {}
local rd_plugin = Lardo:new{ ui = {}, document = {} } -- reader: has a document
check(#UIManager.ticks == 0, "reader instance does not take over the screen")
check(rd_plugin ~= nil and fm_plugin ~= nil, "both instances created")
-- and only once per session
Lardo:new{ ui = {} }
check(#UIManager.ticks == 0, "start-up takeover happens only once")
G_reader_settings:saveSetting("start_with", "filemanager")

--== list, filtering and browser ===========================================
local Recipe = require("lardorecipe")
plugin.list = {
    Recipe.normalizeSummary({ slug = "pancakes", name = "Pancakes", totalTime = "20 min" }),
    Recipe.normalizeSummary({ slug = "lasagne", name = "Lasagne", description = "with pancake sheets" }),
    Recipe.normalizeSummary({ slug = "soup", name = "Tomato soup" }),
}

local items, title = plugin:buildItemTable()
check(#items == 3, "all recipes listed", #items)
-- sorted by name by default, whatever order the server sent
check(items[1].text == "Lasagne" and items[3].text == "Tomato soup",
    "the list is sorted by name", items[1].text .. " / " .. items[3].text)
check(items[2].text == "Pancakes", "item text is the recipe name", items[2].text)
check(items[2].mandatory == "20 min", "total time shown in the mandatory column")
check(items[2].recipe.slug == "pancakes", "item carries the recipe")
-- one line of chrome: the count, and no second line saying "Lardo"
check(title == "3 recipes in Mealie", "the title is the count itself", title)

plugin.filter = "pancake"
items, title = plugin:buildItemTable()
check(#items == 2, "filter matches name and description", #items)
check(title == "Filter: pancake   2/3", "and that same line says what it is filtered by",
    title)
-- the trailing cursor belongs to typing, and to nothing else
plugin.filtering = true
local _items, typing_title = plugin:buildItemTable()
check(typing_title == "Filter: pancake_   2/3", "with a cursor on it while it is typed in",
    typing_title)
plugin.filtering = false
check(#plugin.current_list == 2, "current_list follows the filter")

plugin.filter = "zzz"
items = plugin:buildItemTable()
check(#items == 1 and items[1].dim == true, "empty result shows a hint item")
check(items[1].recipe == nil, "hint item is not selectable")
plugin.filter = nil

--== the rows carry their tags, and the filter reads them ==================
-- What a recipe *is* is mostly its tags: on three hundred recipes "obiad"
-- next to the name is most of what tells two chicken dishes apart.
plugin.list = {
    Recipe.normalizeSummary({ slug = "pancakes", name = "Pancakes", totalTime = "20 min",
        tags = { { name = "śniadanie" } } }),
    Recipe.normalizeSummary({ slug = "soup", name = "Tomato soup",
        tags = { { name = "obiad" }, { name = "zupa" } } }),
}
plugin.sorted_list = nil
items = plugin:buildItemTable()
check(items[1].mandatory == "śniadanie · 20 min",
    "a row shows its tags, then its time", items[1].mandatory)
check(items[2].mandatory == "obiad, zupa", "and tags alone when there is no time",
    items[2].mandatory)

plugin.filter = "zupa"
items = plugin:buildItemTable()
check(#items == 1 and items[1].recipe.slug == "soup",
    "typing a tag finds the recipes carrying it", #items)
plugin.filter = "ŚNIADANIE"
items = plugin:buildItemTable()
check(#items == 1 and items[1].recipe.slug == "pancakes",
    "and the case of what you type does not matter, accents and all", #items)

-- the column is a question about the width of the screen; the filter is a
-- question about what you meant, and they are not the same question
plugin.settings:saveSetting("list_tags", false)
plugin.sorted_list = nil
plugin.filter = "zupa"
items = plugin:buildItemTable()
check(#items == 1, "the filter still reads tags with the column switched off", #items)
plugin.filter = nil
items = plugin:buildItemTable()
check(items[1].mandatory == "20 min" and items[2].mandatory == "",
    "and the rows are back to the time alone",
    items[1].mandatory .. " / " .. items[2].mandatory)
plugin.settings:saveSetting("list_tags", nil)

plugin.list = {
    Recipe.normalizeSummary({ slug = "pancakes", name = "Pancakes", totalTime = "20 min" }),
    Recipe.normalizeSummary({ slug = "lasagne", name = "Lasagne", description = "with pancake sheets" }),
    Recipe.normalizeSummary({ slug = "soup", name = "Tomato soup" }),
}
plugin.sorted_list = nil

plugin:showBrowser()
check(plugin.browser ~= nil, "browser created")
check(#plugin.browser.item_table == 3, "browser got the item table")
-- Menu forwards this flag as `title_bar_fm_style and <number>`: false would
-- reach TitleBar's arithmetic as false and take KOReader down with it, so the
-- single-line title bar has to come from leaving it unset.
check(require("lardobrowser").title_bar_fm_style == nil,
    "the FileManager title-bar style is left unset, never set to false")

--== typing on the list filters it =========================================
-- Menu binds every letter to "open the row with that shortcut", which is both
-- a surprising way to open a recipe and a waste of a keyboard.
check(plugin.browser.is_enable_shortcut == false,
    "the letter shortcuts are off where the letters are needed for typing")
check(plugin.browser.key_events.LardoFilterLetter ~= nil, "letters are bound to the filter")
plugin.browser:onLardoFilterLetter(nil, { key = "P" })
plugin.browser:onLardoFilterLetter(nil, { key = "A" })
check(plugin.filter == "pa", "typing builds the filter, in lower case", plugin.filter)
check(#plugin.browser.item_table == 2, "and the list narrows as you type",
    #plugin.browser.item_table)
check(plugin.browser.title == "Filter: pa_   2/3", "the title shows what was typed",
    plugin.browser.title)
plugin.browser:onLardoFilterSpace()
plugin.browser:onLardoFilterBackspace()
check(plugin.filter == "pa", "Del takes the last character back", plugin.filter)
plugin.browser:onLardoFilterLetter(nil, { key = "Z" })
check(#plugin.browser.item_table == 1 and plugin.browser.item_table[1].dim == true,
    "a filter matching nothing leaves the hint item")
check(plugin.browser:onClose() == true, "Back clears the filter first")
check(plugin.filter == nil, "so the list is whole again")
check(#plugin.browser.item_table == 3, "with every recipe back", #plugin.browser.item_table)
check(plugin.browser.closed ~= true, "and the list itself is still open")

-- ...and with no filter to clear, Back does nothing at all: leaving Lardo is
-- a menu action, not a key that can be brushed while cooking
plugin.browser:onClose()
check(plugin.browser ~= nil, "a second Back keeps the list open")
check(plugin.browser.closed ~= true, "the list was not closed underneath us")

-- "Filter recipes" from the menu opens the same box the keyboard does
plugin:startFiltering()
check(plugin.filtering == true, "the menu entry starts filtering")
check(plugin.browser.title == "Filter: _   3/3",
    "with an empty box waiting for the first letter", plugin.browser.title)
plugin.browser:onLardoFilterLetter(nil, { key = "T" })
check(plugin.filter == "t" and #plugin.browser.item_table == 2,
    "and typing carries straight on from there",
    plugin.filter .. " -> " .. #plugin.browser.item_table)
plugin.browser:onClose()
check(plugin.filtering == false and plugin.filter == nil, "Back leaves the box again")

plugin.browser:onCloseAllMenus()
check(plugin.browser == nil, "only \"Close Lardo\" closes the list")

--== refresh + open a recipe over the (stubbed) network ====================
plugin.settings:saveSetting("url", "http://mealie.lan:9000")
plugin.settings:saveSetting("token", "tok")
next_responses = {
    { code = 200, body = '{items={{slug="pancakes",name="Pancakes",totalTime="20 min"}},total=1,total_pages=1}' },
}
plugin:refreshList()
check(#plugin.list == 1 and plugin.list[1].slug == "pancakes", "refreshList stores normalized summaries")
check(plugin.cache:readSetting("list_time") ~= nil, "refresh time recorded")

plugin:buildItemTable()
next_responses = {
    { code = 200, body = '{slug="pancakes",name="Pancakes",recipeIngredient={{display="2 eggs"}},recipeInstructions={{text="Fry."}}}' },
}
plugin:showRecipeAt(1)
check(plugin.viewer ~= nil, "recipe viewer shown")
check(plugin.viewer.title == "Pancakes", "viewer title is the recipe name")
check(plugin.viewer:findChapter("ingredients") ~= nil, "viewer has an ingredients chapter")
check(plugin.viewer.chapters[plugin.viewer:findChapter("ingredients")].text:find("2 eggs", 1, true) ~= nil,
    "the ingredients chapter has the ingredients")
check(plugin:getCachedRecipe("pancakes") ~= nil, "recipe cached after download")
check(plugin.viewer.next_recipe_callback == nil, "no next-recipe callback for a single recipe")

-- second open comes from the cache (no response queued: a request would fail)
next_responses = {}
plugin.viewer = nil
plugin:showRecipeAt(1)
check(plugin.viewer ~= nil, "cached recipe opens without the network")

-- and closing it lets go of the text: it is on the device, the next open reads
-- it again, and nothing of it stays in a Kindle's 256 MB
check(plugin.current_recipe ~= nil, "the open recipe is held while it is open")
plugin.viewer.close_callback()
check(plugin.current_recipe == nil, "and dropped when the view closes")
plugin.viewer = nil

plugin:clearCache()
check(#UIManager.shown > 0, "clearCache asks for confirmation")

--== incremental sync ======================================================
-- Mealie returns updatedAt on the cheap summary endpoint, so one list request
-- is enough to decide what to add, re-download and drop.
local NetworkMgr = require("ui/network/manager")
plugin:forgetAllRecipes()
plugin.list = {}

local function listResponse(body) next_responses = { { code = 200, body = body } } end

-- one operation: the list, and with it whatever the list says is missing or
-- out of date. "Refresh" and "Sync all" used to be two entries doing this.
request_count = 0
next_responses = {
    { code = 200, body = '{items={{slug="a",name="A",updatedAt="t1"},{slug="b",name="B",updatedAt="t1"}},total=2,total_pages=1}' },
    { code = 200, body = '{slug="a",name="A",updatedAt="t1",recipeInstructions={{text="A1"}}}' },
    { code = 200, body = '{slug="b",name="B",updatedAt="t1",recipeInstructions={{text="B1"}}}' },
}
plugin:refreshList()
check(#plugin.list == 2, "two recipes listed", #plugin.list)
check(plugin.list[1].updated_at == "t1", "version stamp taken from the list", plugin.list[1].updated_at)
check(request_count == 3, "one request for the list, one for each recipe body", request_count)
check(plugin:countCachedRecipes() == 2, "so a refresh leaves everything readable offline")

-- Progress messages are what a sync spends its time on, not the JSON: every
-- Trapper:info() repaints the screen and waits to see whether it was dismissed.
-- One message for the whole download, moved on a timer -- never one per recipe.
local Trapper = require("ui/trapper")
local info_calls = 0
local plain_info = Trapper.info
Trapper.info = function(self, ...) info_calls = info_calls + 1 return plain_info(self, ...) end
plugin:forgetAllRecipes()
next_responses = {
    { code = 200, body = '{items={{slug="a",name="A",updatedAt="t1"},{slug="b",name="B",updatedAt="t1"},' ..
        '{slug="c",name="C",updatedAt="t1"}},total=3,total_pages=1}' },
    { code = 200, body = '{slug="a",name="A",updatedAt="t1",recipeInstructions={{text="A1"}}}' },
    { code = 200, body = '{slug="b",name="B",updatedAt="t1",recipeInstructions={{text="B1"}}}' },
    { code = 200, body = '{slug="c",name="C",updatedAt="t1",recipeInstructions={{text="C1"}}}' },
}
plugin:refreshList()
check(plugin:countCachedRecipes() == 3, "three recipes downloaded", plugin:countCachedRecipes())
check(info_calls <= 2, "one message for the list and one for the download, whatever the count",
    info_calls)
Trapper.info = plain_info

-- nothing moved on the server: the list request, and nothing else
request_count = 0
listResponse('{items={{slug="a",name="A",updatedAt="t1"},{slug="b",name="B",updatedAt="t1"}},total=2,total_pages=1}')
plugin:refreshList()
check(request_count == 1, "an unchanged recipe is never downloaded again", request_count)
check(plugin:countCachedRecipes() == 2, "cache untouched by a no-op refresh")

-- b was edited, c is new, a was deleted
request_count = 0
next_responses = {
    { code = 200, body = '{items={{slug="b",name="B",updatedAt="t2"},{slug="c",name="C",updatedAt="t1"}},total=2,total_pages=1}' },
    { code = 200, body = '{slug="b",name="B",updatedAt="t2",recipeInstructions={{text="B2"}}}' },
    { code = 200, body = '{slug="c",name="C",updatedAt="t1",recipeInstructions={{text="C1"}}}' },
}
plugin:refreshList()
check(plugin:getCachedRecipe("a") == nil, "a recipe deleted on the server is dropped from the device")
check(request_count == 3, "only the changed and the new recipe are requested", request_count)
check(plugin:getCachedRecipe("b").steps[1].text == "B2", "the edited recipe was replaced",
    plugin:getCachedRecipe("b").steps[1].text)
check(plugin:getCachedRecipe("c") ~= nil, "the new recipe was added")
check(plugin:countCachedRecipes() == 2, "and nothing else is left behind", plugin:countCachedRecipes())

-- a server that sends no stamps at all must not cause endless re-downloads
next_responses = {
    { code = 200, body = '{items={{slug="d",name="D"}},total=1,total_pages=1}' },
    { code = 200, body = '{slug="d",name="D",recipeInstructions={{text="D1"}}}' },
}
plugin:refreshList()
request_count = 0
listResponse('{items={{slug="d",name="D"}},total=1,total_pages=1}')
plugin:refreshList()
check(request_count == 1, "without stamps, a stored recipe is still not re-downloaded", request_count)

-- an empty list is "we do not know", not "everything was deleted"
plugin.list = {}
check(plugin:pruneCache() == 0, "an empty list never wipes the cache")
check(plugin:countCachedRecipes() == 1, "cache survives an unknown list")

--== one file per recipe, and an index of stamps ===========================
-- The recipes used to be one table in the settings file: parsed at every
-- start-up and held in RAM for the whole run, to draw a list of names.
plugin:forgetAllRecipes()
next_responses = {
    { code = 200, body = '{items={{slug="pancakes",name="Pancakes",updatedAt="t1"}},total=1,total_pages=1}' },
    { code = 200, body = '{slug="pancakes",name="Pancakes",updatedAt="t1",recipeInstructions={{text="Fry."}}}' },
}
plugin:refreshList()
local recipe_path = plugin:recipePath("pancakes")
local stored_file = io.open(recipe_path)
check(stored_file ~= nil, "the recipe is written as a file of its own", recipe_path)
if stored_file then stored_file:close() end
check(plugin.cache:readSetting("recipes") == nil, "nothing about it in the settings file")
check(plugin:cachedStamp("pancakes") == "t1", "except its stamp, in the index",
    tostring(plugin:cachedStamp("pancakes")))
check(plugin:getCachedRecipe("pancakes").steps[1].text == "Fry.",
    "and it reads back off the device")

-- drawing the list and working out what to download must not open any of them
local reads = 0
local real_get = plugin.getCachedRecipe
plugin.getCachedRecipe = function(this, slug) reads = reads + 1 return real_get(this, slug) end
plugin:buildItemTable()
check(#plugin:pendingSync() == 0, "nothing left to sync")
check(reads == 0, "neither the list nor the sync opens a stored recipe", reads)
plugin.getCachedRecipe = real_get

-- a recipe file that goes missing (a half-copied card, a manual delete) takes
-- its stamp with it, or the next refresh would still believe we had it
os.remove(recipe_path)
check(plugin:getCachedRecipe("pancakes") == nil, "a missing file reads as no recipe")
check(plugin:cachedStamp("pancakes") == nil, "and its stamp is dropped with it")
check(#plugin:pendingSync() == 1, "so the next refresh downloads it again",
    #plugin:pendingSync())

-- a cache written by the previous version is moved into the new shape once
plugin:forgetAllRecipes()
plugin.cache:saveSetting("recipes", {
    old = { slug = "old", name = "Old", updated_at = "t9", steps = { { text = "Stir." } } },
})
plugin:migrateRecipeCache(plugin.cache:readSetting("recipes"))
check(plugin.cache:readSetting("recipes") == nil, "the old key is gone")
check(plugin:cachedStamp("old") == "t9", "the stamp survived the move")
check(plugin:getCachedRecipe("old").steps[1].text == "Stir.", "and so did the recipe")

-- deleting the downloaded recipes takes the files with it
plugin:forgetAllRecipes()
check(io.open(recipe_path) == nil, "the files go when the cache is cleared")
check(plugin:getCachedRecipe("pancakes") == nil, "and nothing reads back afterwards")
check(plugin:countCachedRecipes() == 0, "with an empty index to match")

--== favourites and sorting ================================================
-- Favourites belong to the user, not to the recipe, so they come from their
-- own endpoint (/api/users/self, then /api/users/{id}/favorites).
favorite_ids = { "id-b" }
user_request_count = 0
next_responses = {
    { code = 200, body = '{items={' ..
        '{id="id-a",slug="a",name="Apple pie",updatedAt="t1",dateAdded="2024-01-01"},' ..
        '{id="id-b",slug="b",name="Borscht",updatedAt="t3",dateAdded="2023-01-01"},' ..
        '{id="id-c",slug="c",name="Cake",updatedAt="t2",dateAdded="2025-01-01"}' ..
        '},total=3,total_pages=1}' },
    { code = 200, body = '{slug="a",name="Apple pie",updatedAt="t1",recipeInstructions={{text="A"}}}' },
    { code = 200, body = '{slug="b",name="Borscht",updatedAt="t3",recipeInstructions={{text="B"}}}' },
    { code = 200, body = '{slug="c",name="Cake",updatedAt="t2",recipeInstructions={{text="C"}}}' },
}
plugin:forgetAllRecipes()
plugin:refreshList()
check(user_request_count == 2, "the refresh asks who we are and what we starred",
    user_request_count)
local function names()
    local out = {}
    local list_items = plugin:buildItemTable()
    for i = 1, #list_items do out[i] = list_items[i].text end
    return table.concat(out, ", ")
end
check(names():find("★ Borscht", 1, true) ~= nil, "a favourite is starred in the list", names())

plugin.settings:saveSetting("sort_by", "name")
check(names() == "Apple pie, ★ Borscht, Cake", "sorted by name", names())
plugin.settings:saveSetting("sort_by", "added")
check(names() == "Cake, Apple pie, ★ Borscht", "newest first by the date added", names())
plugin.settings:saveSetting("sort_by", "updated")
check(names() == "★ Borscht, Cake, Apple pie", "recently changed first", names())
plugin.settings:saveSetting("sort_by", "favorites")
check(names() == "★ Borscht, Apple pie, Cake", "favourites first, then by name", names())
plugin.settings:saveSetting("sort_by", "nonsense")
check(plugin:getSortOrder() == "name", "an unknown order falls back to the name")
plugin.settings:saveSetting("sort_by", nil)

-- a Mealie without the favourites endpoint must not break the refresh
local real_favorites = plugin:getApi().getFavoriteIds
getmetatable(plugin:getApi()).getFavoriteIds = function() error("no such endpoint") end
next_responses = {
    { code = 200, body = '{items={{id="id-a",slug="a",name="Apple pie",updatedAt="t1"}},total=1,total_pages=1}' },
    { code = 200, body = '{slug="a",name="Apple pie",updatedAt="t1",recipeInstructions={{text="A"}}}' },
}
plugin:forgetAllRecipes()
plugin:refreshList()
check(#plugin.list == 1 and plugin.list[1].favorite == nil,
    "an old server just means no stars")
getmetatable(plugin:getApi()).getFavoriteIds = real_favorites
favorite_ids = {}

--== opening a recipe respects the stamp ===================================
plugin:forgetAllRecipes()
plugin.list = { Recipe.normalizeSummary({ slug = "b", name = "B", updatedAt = "t2" }) }
plugin:buildItemTable()
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t2",recipeInstructions={{text="B2"}}}' } }
plugin.viewer = nil
plugin:showRecipeAt(1)
check(plugin.viewer ~= nil and plugin.viewer.chapters[plugin.viewer:findChapter("instructions")].text:find("B2", 1, true) ~= nil,
    "recipe downloaded on first open")

request_count = 0
plugin.viewer = nil
plugin:showRecipeAt(1)
check(request_count == 0, "an up-to-date recipe opens straight from the device", request_count)

plugin.list = { Recipe.normalizeSummary({ slug = "b", name = "B", updatedAt = "t3" }) }
plugin:buildItemTable()
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t3",recipeInstructions={{text="B3"}}}' } }
request_count = 0
plugin.viewer = nil
plugin:showRecipeAt(1)
check(request_count == 1, "a stale recipe is refreshed when we are online", request_count)
check(plugin.viewer.chapters[plugin.viewer:findChapter("instructions")].text:find("B3", 1, true) ~= nil, "the refreshed text is shown")

plugin.list = { Recipe.normalizeSummary({ slug = "b", name = "B", updatedAt = "t4" }) }
plugin:buildItemTable()
NetworkMgr.online = false
request_count = 0
next_responses = {}
plugin.viewer = nil
plugin:showRecipeAt(1)
check(request_count == 0, "offline: a stale recipe does not trigger a request", request_count)
check(plugin.viewer ~= nil and plugin.viewer.chapters[plugin.viewer:findChapter("instructions")].text:find("B3", 1, true) ~= nil,
    "offline: the stored copy is shown instead of nothing")
NetworkMgr.online = true

--== UI edits are written back into lardo.conf ==============================
writeConf(table.concat({
    "# my notes",
    "url = http://old.lan",
    "token = tok-keep",
    "username = u",
    "password = p",
    "",
}, "\n"))
plugin = Lardo:new{}
check(plugin.settings:readSetting("url") == "http://old.lan", "starting point read from the file")

plugin:editServerUrl()
local url_dialog = UIManager.shown[#UIManager.shown]
url_dialog.input = "http://new.lan:9000"
url_dialog.buttons[1][2].callback() -- "Save"

local function readConf()
    local f = assert(io.open(conf_path, "r"))
    local content = f:read("*a")
    f:close()
    return content
end
local on_disk = readConf()
check(on_disk:find("url = http://new.lan:9000", 1, true) ~= nil,
    "the address edited in KOReader lands in lardo.conf", on_disk)
check(on_disk:find("http://old.lan", 1, true) == nil, "the old address is gone from the file")
check(on_disk:find("token = tok-keep", 1, true) ~= nil, "the token in the file is left alone")
check(on_disk:find("password = p", 1, true) ~= nil, "credentials in the file are left alone")
check(on_disk:find("# my notes", 1, true) ~= nil, "comments in the file are left alone")
check(plugin:importConfigFile(false) == false,
    "writing the file ourselves does not look like an external change")

plugin:editToken()
local token_dialog = UIManager.shown[#UIManager.shown]
token_dialog.input = "tok-from-ui"
token_dialog.buttons[1][2].callback()
check(readConf():find("token = tok%-from%-ui") ~= nil, "a token edited in KOReader lands in the file", readConf())
os.remove(conf_path)

--== recipe view =========================================================
local LardoView = require("lardoview")
local Font = require("ui/font")

local function longText(prefix, lines)
    local out = {}
    for i = 1, lines do out[i] = prefix .. " " .. i end
    return table.concat(out, "\n")
end
local function viewChapters()
    return {
        { id = "description",  title = "Description",  text = longText("d", 100) },
        { id = "ingredients",  title = "Ingredients",  text = longText("i", 100) },
        { id = "instructions", title = "Instructions", text = longText("s", 100) },
    }
end

local view = LardoView:new{ title = "Carbonara", meta = "45 min", chapters = viewChapters() }
check(view.chapter_index == 1, "opens on the first chapter")
check(view:findChapter("ingredients") == 2, "finds the ingredients chapter")
check(view.text_widget.lines_per_page > 1, "the body gets a usable height", view.text_widget.lines_per_page)
check(view.text_widget.text == view.chapters[1].text, "the body shows the current chapter")

-- keys: scrolling wins over focus movement, chapters get their own keys
check(view.key_events.FocusUp == nil and view.key_events.FocusDown == nil,
    "Up/Down are taken from the focus manager")
check(view.key_events.LardoLineUp ~= nil and view.key_events.LardoLineDown ~= nil,
    "Up/Down scroll the text")
check(view.key_events.LardoChapterNext ~= nil, "Right moves to the next chapter with no buttons")
check(view.key_events.FocusLeft == nil, "Left/Right are taken over when there is nothing to focus")
check(view.key_events.LardoIngredients ~= nil, "\"S\" is bound")
check(view.key_events.LardoChapter3 ~= nil, "digit keys jump to a chapter")
check(view.key_events.LardoChapter4 == nil, "no digit key for a chapter that does not exist")
check(view.key_events.LardoNextRecipe ~= nil, "Shift + page key switches recipe")

-- "S" and the chapter keys
view:onLardoIngredients()
check(view.chapter_index == 2, "jumped to the ingredients")
check(view.text_widget.text == view.chapters[2].text, "the body followed the jump")
view:onLardoChapter("next")
check(view.chapter_index == 3, "next chapter")
view:onLardoChapter("next")
check(view.chapter_index == 1, "next wraps around")
view:onLardoChapter("previous")
check(view.chapter_index == 3, "previous wraps around")

-- page keys scroll, and roll over into the neighbouring chapter like a book
view:onLardoChapter(1)
local scrolls = 0
while view.chapter_index == 1 and scrolls < 50 do
    view:onLardoScrollPage(1)
    scrolls = scrolls + 1
end
check(scrolls > 1, "paging scrolls within the chapter before moving on", scrolls)
check(view.chapter_index == 2, "paging past the end opens the next chapter", view.chapter_index)
check(view.text_widget.virtual_line_num == 1, "the next chapter starts at the top")
view:onLardoScrollPage(-1)
check(view.chapter_index == 1, "paging back at the top returns to the previous chapter")
check(view.text_widget.virtual_line_num > 1, "and lands on its last page",
    view.text_widget.virtual_line_num)

--== chapter row and per-chapter progress ================================
-- a fresh view, so the paging above does not count as "already read"
view = LardoView:new{ title = "Carbonara", meta = "45 min", chapters = viewChapters() }
-- every chapter is always listed, and each has its own segment of the bar
view:onLardoChapter(1)
check(view.chapter_spans ~= nil and #view.chapter_spans == 3,
    "one span per chapter in the header row", view.chapter_spans and #view.chapter_spans)
check(view.progress_line.segments == view.chapter_spans,
    "the bar segments line up with the chapter names")
for i = 1, #view.chapter_spans - 1 do
    check(view.chapter_spans[i].x + view.chapter_spans[i].w <= view.chapter_spans[i + 1].x,
        "chapter spans do not overlap")
end

view.text_widget:scrollToTop()
view:updateProgress()
check(view.progress_line.segments[1].ratio < 0.9, "the current chapter starts unfilled",
    view.progress_line.segments[1].ratio)
check(view.progress_line.segments[2].ratio == 0, "an unread chapter is empty")
view.text_widget:scrollToBottom()
view:updateProgress()
check(view.progress_line.segments[1].ratio > 0.9, "reading fills its own segment",
    view.progress_line.segments[1].ratio)
check(view.progress_line.segments[3].ratio == 0, "and only its own")
view:onLardoChapter(3)
view:updateProgress()
check(view.progress_line.segments[1].ratio > 0.9, "a chapter already read stays filled",
    view.progress_line.segments[1].ratio)
check(view.progress_line.segments[2].ratio == 0, "the skipped chapter stays empty")

-- "S" toggles: to the ingredients, then back where we were
view:onLardoChapter(3)
local scrolls_before = 3
view.text_widget:scrollLines(scrolls_before - 1)
local line_before = view.text_widget.virtual_line_num
view:onLardoIngredients()
check(view.chapter_index == 2, "S jumps to the ingredients", view.chapter_index)
view:onLardoIngredients()
check(view.chapter_index == 3, "S again returns to the chapter we came from", view.chapter_index)
check(view.text_widget.virtual_line_num == line_before, "and to the same place in it",
    view.text_widget.virtual_line_num .. " vs " .. line_before)
view:onLardoIngredients()
check(view.chapter_index == 2, "and it can be used again")
view:onLardoChapter(1)

-- the chapter names: all listed, the current one highlighted
local row = view:buildChapterRow(600, 8, Font:getFace("cfont", 15))
local names = {}
for i = 1, #row do
    if row[i].text then table.insert(names, row[i]) end
end
check(#names == 3, "every chapter is named in the header", #names)
check(names[1].text == "Description" and names[3].text == "Instructions", "in order")
check(names[1].bold == true, "the chapter being read is bold")
check(names[2].bold == false and names[3].bold == false, "the others are not")
check(names[1].fgcolor ~= names[2].fgcolor, "and it is darker than the rest")
view:onLardoChapter(2)
row = view:buildChapterRow(600, 8, Font:getFace("cfont", 15))
names = {}
for i = 1, #row do
    if row[i].text then table.insert(names, row[i]) end
end
check(names[2].bold == true and names[1].bold == false, "the highlight follows the chapter")
view:onLardoChapter(1)

-- progress bar placement
check(view.progress_line.vertical == false, "the top bar is horizontal")
local side_view = LardoView:new{ chapters = viewChapters(), progress_position = "side" }
check(side_view.progress_line ~= nil and side_view.progress_line.vertical == true, "side bar is vertical")
check(side_view.text_widget.width < view.text_widget.width, "the side bar takes width from the text")
-- the side bar must sit against the screen edge, not float inside a margin
local Size = require("ui/size")
check(side_view.text_widget.width == 600 - 2 * Size.padding.large - side_view.progress_line.width,
    "nothing is left over to the right of the side bar", side_view.text_widget.width)
local bare_view = LardoView:new{ chapters = viewChapters(), progress_position = "off" }
check(bare_view.progress_line == nil, "the bar can be switched off")
check(bare_view.text_widget.lines_per_page >= view.text_widget.lines_per_page,
    "switching the bar off gives the text at least as much room")

-- the focus keys must be taken even on a KOReader without releaseFocusKeys
local FocusManagerStub = require("ui/widget/focusmanager")
local real_release = FocusManagerStub.releaseFocusKeys
FocusManagerStub.releaseFocusKeys = nil
local old_ko_view = LardoView:new{ chapters = viewChapters() }
check(old_ko_view.key_events.FocusUp == nil and old_ko_view.key_events.FocusLeft == nil,
    "focus keys are dropped even without releaseFocusKeys()")
check(old_ko_view.key_events.LardoLineDown ~= nil, "and our own bindings are still there")
FocusManagerStub.releaseFocusKeys = real_release

-- a single chapter needs no chapter chrome
local one_view = LardoView:new{ chapters = { { id = "description", title = "Description", text = "short" } } }
check(one_view.key_events.LardoChapterNext == nil, "no chapter keys for a single chapter")

--== the same recipe, with a finger =======================================
-- A touch device has no page keys, no Back and no Menu key: without gestures
-- an opened recipe would be a room with no doors.
local DeviceStub = require("device")
local real_is_touch = DeviceStub.isTouchDevice
DeviceStub.isTouchDevice = function() return true end

local touch_view = LardoView:new{ chapters = viewChapters(), meta = "45 min" }
check(touch_view.ges_events.LardoTap ~= nil, "taps are bound")
check(touch_view.ges_events.LardoSwipe ~= nil, "and swipes")
check(touch_view.ges_events.LardoHold ~= nil, "and a long press")
check(touch_view.header_height and touch_view.header_height > 0,
    "the header knows how tall it is, so a tap can tell chrome from text",
    tostring(touch_view.header_height))

local body_y = touch_view.header_height + 10
check(touch_view:tapZone({ x = 500, y = body_y }) == "forward", "the right of the page turns forward")
check(touch_view:tapZone({ x = 20, y = body_y }) == "back", "its left edge turns back")
check(touch_view:tapZone({ x = 300, y = 5 }) == "header", "the header is its own zone")

local line_at_start = touch_view.text_widget.virtual_line_num
touch_view:onLardoTap(nil, { pos = { x = 500, y = body_y } })
check(touch_view.text_widget.virtual_line_num > line_at_start, "tapping right scrolls on",
    touch_view.text_widget.virtual_line_num)
touch_view:onLardoTap(nil, { pos = { x = 20, y = body_y } })
check(touch_view.text_widget.virtual_line_num == line_at_start, "tapping left scrolls back")

touch_view:onLardoSwipe(nil, { direction = "west" })
check(touch_view.chapter_index == 2, "a swipe moves to the next chapter", touch_view.chapter_index)
touch_view:onLardoSwipe(nil, { direction = "east" })
check(touch_view.chapter_index == 1, "and back to the previous one")

-- The header is the menu, and at its end the way out. It used to be two things
-- at once with nothing to tell them apart -- tap the title and the recipe you
-- were cooking from was gone, tap beside it and the menu opened, and the two
-- halves looked exactly alike. Now the only thing that closes is a ✕ drawn
-- where a ✕ is drawn, and everything else up there is the menu.
local menu_opened = 0
touch_view.menu_callback = function() menu_opened = menu_opened + 1 end
local closed = 0
touch_view.close_callback = function() closed = closed + 1 end
local line_before_header_tap = touch_view.text_widget.virtual_line_num
check(touch_view.close_zone ~= nil and touch_view.close_zone.from_x < 600,
    "a touch screen gets a ✕ at the end of the header")
check(touch_view.header_right_widget.text:find("✕", 1, true) ~= nil,
    "and it is drawn there, not merely tappable",
    touch_view.header_right_widget.text)
touch_view:onLardoTap(nil, { pos = { x = 100, y = 5 } })
check(menu_opened == 1 and closed == 0, "a tap on the header opens the menu",
    menu_opened .. "/" .. closed)
touch_view:onLardoTap(nil, { pos = { x = 599, y = 5 } })
check(closed == 1, "and a tap on the ✕ is the way out", closed)
-- the zone is that line, not the chapter names under it
check(touch_view:tapZone({ x = 599, y = touch_view.close_zone.to_y + 1 }) == "header",
    "below it the same corner is the menu again, not another way out")
check(touch_view.text_widget.virtual_line_num == line_before_header_tap,
    "and none of it turns the page")
touch_view:onLardoHold()
check(menu_opened == 2, "a long press anywhere is still the menu", menu_opened)

-- and the same habit works on the recipe list, where the top of the screen is
-- the one line of chrome. KOReader's own "tap the top for the menu" touch zone
-- belongs to the file manager, and a full-screen widget of ours covers it.
plugin.browser = nil
plugin:showBrowser()
local touch_list = plugin.browser
check(touch_list.ges_events.LardoHeaderTap ~= nil, "the list's chrome takes a tap")
local list_menu_opened, list_filter_started = 0, 0
touch_list.menu_button_callback = function() list_menu_opened = list_menu_opened + 1 end
touch_list.search_button_callback = function() list_filter_started = list_filter_started + 1 end
touch_list:onLardoHeaderTap()
check(list_menu_opened == 1, "which opens the same menu the Menu button does",
    list_menu_opened)

-- ...but that line is not blank strip: it is the recipe count, and while you
-- are typing it is the filter box. Tapping the words does what they are about;
-- tapping beside them is the menu, the way it is everywhere else in KOReader.
do
    local title_w = touch_list.title_bar.title_widget:getWidth()
    local beside_x = (600 - title_w) / 2 - 20
    check(title_w > 0 and beside_x > 0, "the title is narrower than the strip it sits in",
        title_w)
    touch_list:onLardoHeaderTap(nil, { pos = { x = 300, y = 5 } })
    check(list_filter_started == 1, "a tap on the words starts the filter",
        list_filter_started)
    touch_list:onLardoHeaderTap(nil, { pos = { x = beside_x, y = 5 } })
    check(list_menu_opened == 2 and list_filter_started == 1,
        "and a tap beside them opens the menu",
        list_menu_opened .. "/" .. list_filter_started)
end
-- the zone stops at the title bar: with the row at the top it sits directly
-- below, and a button that opens the menu because it was missed is not a button
local zone = touch_list.ges_events.LardoHeaderTap[1].range
check(zone.y == 0 and zone.h == touch_list.title_bar:getHeight(),
    "and no further down than the chrome itself",
    tostring(zone.y) .. "+" .. tostring(zone.h))

-- Filter, on a device with no keys: the same box the keyboard device has, in
-- the same line, with the keyboard under it -- and the list narrowing on every
-- letter. It used to be a dialog in the middle of the screen that filtered only
-- once it was confirmed, which is a different thing wearing the same word.
do
    local real_keyboard = DeviceStub.hasKeyboard
    DeviceStub.hasKeyboard = function() return false end
    plugin.list = {}
    for i = 1, 6 do
        plugin.list[i] = Recipe.normalizeSummary({
            slug = "f" .. i, name = (i <= 2 and "Pancakes " or "Soup ") .. i })
    end
    plugin.filter = nil
    plugin:updateBrowserItems()
    local before = #touch_list.item_table

    UIManager.shown = {}
    plugin:startFiltering()
    local field = touch_list.filter_input
    check(field ~= nil and field.keyboard_shown == true,
        "the Filter button opens the field itself, with its keyboard")
    check(UIManager.shown[#UIManager.shown] == touch_list.filter_field,
        "over the line the count is in, not in a window of its own")

    field:addChars("p")
    field:addChars("a")
    check(plugin.filter == "pa", "what is typed is the filter", tostring(plugin.filter))
    check(#touch_list.item_table < before,
        "and the list has already narrowed -- nothing to confirm",
        #touch_list.item_table .. " of " .. before)

    field:addChars("\n")
    check(touch_list.filter_input == nil, "Enter puts the keyboard away")
    check(plugin.filter == "pa", "and leaves the filter where it was",
        tostring(plugin.filter))
    check(plugin.filtering == false and select(2, plugin:buildItemTable()) == "Filter: pa   2/6",
        "and the line goes back to saying what the list is filtered by",
        select(2, plugin:buildItemTable()))

    -- a tap anywhere else is the other way out: with the keyboard up there is
    -- nothing else to do on this screen, so nothing else should have to be
    -- aimed at. A tap *on* the field still goes to the field -- children are
    -- asked before the catcher they sit in.
    plugin:startFiltering()
    local catcher = touch_list.filter_field
    local catch = catcher.ges_events and catcher.ges_events.LardoCloseFilterField
    check(catch ~= nil, "the field sits in a catcher that takes taps")
    local reach = catch and catch[1].range or {}
    check(reach.w == 600 and reach.h == 800, "the size of the screen, so anywhere means anywhere",
        tostring(reach.w) .. "x" .. tostring(reach.h))
    -- The keyboard is the topmost widget while it is up, and UIManager offers
    -- what it did not consume *only* to widgets flagged always active. Without
    -- the flag a tap outside the keyboard reached nothing at all.
    check(catcher.is_always_active == true,
        "and is flagged so that a tap the keyboard did not want reaches it")

    -- a tap in the grey between two keys is a miss on the keyboard, not a tap
    -- outside it: it falls through to us, and must not close anything
    local Geometry = require("ui/geometry")
    if catcher.onLardoCloseFilterField then
        catcher:onLardoCloseFilterField(nil, { pos = Geometry:new{ x = 300, y = 600 } })
    end
    check(touch_list.filter_input ~= nil, "a tap that landed on the keyboard changes nothing")
    if catcher.onLardoCloseFilterField then
        catcher:onLardoCloseFilterField(nil, { pos = Geometry:new{ x = 300, y = 300 } })
    end
    check(touch_list.filter_input == nil, "and a tap anywhere else puts the keyboard away")

    -- and backspacing out of an empty field, which is how the filter is left on
    -- a keyboard device: the same key, the second time
    plugin:clearFilter() -- so the field opens empty rather than with "pa" in it
    plugin:startFiltering()
    field = touch_list.filter_input
    field:addChars("z")
    field:delChar()
    check(touch_list.filter_input ~= nil, "backspace over a letter only deletes the letter")
    field:delChar()
    check(touch_list.filter_input == nil, "and over nothing it puts the keyboard away")

    -- opening a recipe is leaving the list; so is clearing the filter
    plugin:startFiltering()
    touch_list:onMenuSelect({})
    check(touch_list.filter_input == nil, "opening a recipe takes the field with it")
    plugin:startFiltering()
    plugin:clearFilter()
    check(touch_list.filter_input == nil and plugin.filter == nil,
        "and so does clearing the filter")

    -- a KOReader that will not have it falls back to the dialog rather than to
    -- nothing at all
    local real_field = touch_list.showFilterField
    touch_list.showFilterField = function() return false end
    UIManager.shown = {}
    plugin:startFiltering()
    local fallback = UIManager.shown[#UIManager.shown]
    check(fallback and fallback.stub_name == "inputdialog",
        "with the old dialog left as the way back out",
        fallback and tostring(fallback.stub_name))
    UIManager:close(fallback)
    touch_list.showFilterField = real_field
    DeviceStub.hasKeyboard = real_keyboard
    plugin.filter = nil
end

touch_list:onCloseAllMenus()
plugin.browser = nil

DeviceStub.isTouchDevice = real_is_touch

local keys_only_view = LardoView:new{ chapters = viewChapters() }
check(keys_only_view.ges_events == nil or keys_only_view.ges_events.LardoTap == nil,
    "nothing is bound to taps where there is no touch screen")
check(keys_only_view.close_zone == nil,
    "and no ✕ is drawn where Back is a key, because nothing could press it")

-- an unloadable font must not leave the view without a face
Font.missing["/no/such/font.ttf"] = true
local font_view = LardoView:new{ chapters = viewChapters(), font_face = "/no/such/font.ttf" }
check(font_view.text_widget.face ~= nil, "falls back to the UI font when the chosen one fails")
check(font_view.text_widget.face.name == "cfont", "and it is KOReader's own content font",
    font_view.text_widget.face.name)
Font.missing["/no/such/font.ttf"] = nil

--== when our own view cannot be built ====================================
-- There used to be a fallback to KOReader's TextViewer here; it was a trap on a
-- keyboard device (its Close button cannot be reached), so it is gone.
local real_view_init = LardoView.init
LardoView.init = function() error("simulated widget incompatibility") end
plugin.viewer = nil
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t9",recipeInstructions={{text="B9"}}}' } }
plugin.list = { Recipe.normalizeSummary({ slug = "b", name = "B", updatedAt = "t9" }) }
plugin:buildItemTable()
plugin:showRecipeAt(1)
check(plugin.viewer == nil, "a broken recipe view opens nothing to get stuck in",
    tostring(plugin.viewer and plugin.viewer.stub_name))
local failure = UIManager.shown[#UIManager.shown]
check(failure ~= nil and tostring(failure.text):find("simulated widget incompatibility", 1, true) ~= nil,
    "it says what went wrong instead", failure and failure.text)
check(plugin.settings:readSetting("simple_viewer") == nil,
    "and nothing is stored that would route later recipes elsewhere")
LardoView.init = real_view_init

local function menuLabels()
    local labels = {}
    local items = plugin:getMenuItems()
    for i = 1, #items do
        labels[i] = items[i].text_func and items[i].text_func() or items[i].text
    end
    return labels
end
local function hasLabel(labels, prefix)
    for i = 1, #labels do
        if tostring(labels[i]):sub(1, #prefix) == prefix then return labels[i] end
    end
end
-- every label of a menu with its categories opened: what a reader can reach
local function allMenuLabels()
    local labels = {}
    local function walk(items, depth)
        for i = 1, #items do
            local item = items[i]
            labels[#labels + 1] = item.text_func and item.text_func() or item.text
            if item.sub_items and depth < 2 then walk(item.sub_items(), depth + 1) end
        end
    end
    walk(plugin:getMenuItems(), 0)
    return labels
end
check(hasLabel(allMenuLabels(), "Simple text viewer") == nil,
    "the simple viewer is not offered as a setting at all")

plugin.viewer = nil
plugin:showRecipeAt(1)
check(plugin.viewer ~= nil and plugin.viewer.chapters ~= nil, "so our own view is what opens",
    tostring(plugin.viewer and plugin.viewer.stub_name))

--== view settings ========================================================
plugin.settings:saveSetting("font_size", 24)
plugin.settings:saveSetting("font_face", "/fonts/Custom.ttf")
plugin.settings:saveSetting("progress_position", "side")
plugin.list = { Recipe.normalizeSummary({ slug = "b", name = "B", updatedAt = "t4" }) }
plugin:buildItemTable()
plugin.viewer = nil
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t4",recipeInstructions={{text="B4"}}}' } }
plugin:showRecipeAt(1)
check(plugin.viewer ~= nil, "recipe opened")
check(plugin.viewer.font_size == 24, "the view uses the stored font size", plugin.viewer.font_size)
check(plugin.viewer.font_face == "/fonts/Custom.ttf", "and the stored typeface")
check(plugin.viewer.progress_position == "side", "and the stored bar position")

plugin:changeFontSize(2)
check(plugin.settings:readSetting("font_size") == 26, "font size setting changed",
    plugin.settings:readSetting("font_size"))
check(plugin.viewer.font_size == 26, "the open view followed")
plugin:applyViewSetting("font_size", 999, "font_size")
plugin:changeFontSize(1)
check(plugin.settings:readSetting("font_size") == 40, "font size is clamped",
    plugin.settings:readSetting("font_size"))

local view_menu = plugin:getFontMenuTable()
local typeface_item = findItem(view_menu, "Typeface: Custom")
check(typeface_item ~= nil, "the menu shows the chosen typeface by name")
local reset_item = findItem(view_menu, "Use KOReader's default typeface")
check(reset_item.enabled_func() == true, "resetting is offered while a font is set")
reset_item.callback()
check(plugin.settings:readSetting("font_face") == nil, "typeface reset to the default")
check(findItem(plugin:getFontMenuTable(), "Typeface: KOReader default") ~= nil,
    "and the menu says so")

check(hasLabel(allMenuLabels(), "Reading position bar: Right edge, whole recipe") ~= nil,
    "the menu reflects the bar position")

--== typeface picker =====================================================
-- KOReader's FontChooser puts its buttons below a long radio list, which a
-- D-pad cannot reach past; we use a Menu instead.
plugin.viewer = nil
plugin:showFontChooser()
local font_menu = UIManager.shown[#UIManager.shown]
check(font_menu ~= nil and font_menu.item_table ~= nil, "the typeface picker is a menu")
check(#font_menu.item_table == 3, "the default plus every installed font",
    font_menu.item_table and #font_menu.item_table)
check(font_menu.item_table[1].text == "KOReader default", "the default comes first")
check(font_menu.item_table[1].mandatory ~= nil, "and is marked as the current one")
check(font_menu.item_table[2].text == "Alpha-Regular", "fonts are named by their file",
    font_menu.item_table[2].text)
-- each row is drawn in the font it offers, so the list previews them
check(font_menu.layout[2][1].font == "/fonts/Alpha-Regular.ttf",
    "a font row is rendered in that font", font_menu.layout[2][1].font)
check(font_menu.layout[2][1].init_count == 1, "the row was rebuilt exactly once for it",
    font_menu.layout[2][1].init_count)
check(font_menu.layout[1][1].font == "smallinfofont",
    "the \"KOReader default\" row keeps the interface font", font_menu.layout[1][1].font)
font_menu:updateItems(1)
check(font_menu.layout[2][1].init_count == 1,
    "and a redraw does not rebuild it again", font_menu.layout[2][1].init_count)

-- a font KOReader lists but cannot load must not break its row
Font.missing["/fonts/Beta-Bold.ttf"] = true
font_menu:updateItems(1)
check(font_menu.layout[3][1].font == "smallinfofont",
    "an unloadable font leaves the row in the interface font", font_menu.layout[3][1].font)
Font.missing["/fonts/Beta-Bold.ttf"] = nil

font_menu:onMenuSelect(font_menu.item_table[2])
check(plugin.settings:readSetting("font_face") == "/fonts/Alpha-Regular.ttf",
    "picking a font applies it straight away, with no button to reach",
    plugin.settings:readSetting("font_face"))

-- the D-pad must cross page boundaries, or a long font list traps the focus
local RecipeBrowser = require("lardobrowser")
local long_items = {}
for i = 1, 12 do long_items[i] = { text = "item " .. i } end
local paged = RecipeBrowser:new{ item_table = long_items, perpage = 5 }
check(paged.page == 1 and #paged.layout == 5, "starts on the first page")
paged.selected.y = 5
paged:onFocusMove({ 0, 1 })
check(paged.page == 2, "down from the last row opens the next page", paged.page)
check(paged.selected.y == 1, "and lands on its first item", paged.selected.y)
paged:onFocusMove({ 0, -1 })
check(paged.page == 1, "up from the first row goes back a page", paged.page)
check(paged.selected.y == #paged.layout, "and lands on its last item", paged.selected.y)
paged.wrapped_focus_move = nil
paged.selected.y = 2
paged:onFocusMove({ 0, 1 })
check(paged.wrapped_focus_move == true, "in the middle of a page Menu still decides")
paged.page = 3
paged:updateItems(1)
paged.selected.y = #paged.layout
paged.wrapped_focus_move = nil
paged:onFocusMove({ 0, 1 })
check(paged.wrapped_focus_move == true, "and on the last page it stops paging")

-- the row under the cursor is inverted, not just underlined
local highlighted = RecipeBrowser:new{ item_table = long_items, perpage = 5 }
check(highlighted.layout[1][1]._lardo_focused == true, "the row under the cursor is marked")
check(highlighted.layout[2][1]._lardo_focused == false, "the other rows are not")
local inverted
local fake_bb = { invertRect = function(_bb, x, y, w, h) inverted = { x, y, w, h } end }
local first_row = highlighted.layout[1][1]
first_row.dimen = { x = 0, y = 10, w = 600, h = 40 }
first_row:paintTo(fake_bb, 0, 10)
check(inverted ~= nil, "the marked row paints an inversion")
check(inverted[3] == 600 and inverted[4] == 40,
    "covering the whole row rather than a hairline", inverted and table.concat(inverted, ","))
inverted = nil
highlighted.layout[2][1].dimen = { x = 0, y = 50, w = 600, h = 40 }
highlighted.layout[2][1]:paintTo(fake_bb, 0, 50)
check(inverted == nil, "an unmarked row paints nothing extra")
highlighted.layout[2][1]:onFocus()
highlighted.layout[1][1]:onUnfocus()
check(highlighted.layout[2][1]._lardo_focused == true and highlighted.layout[1][1]._lardo_focused == false,
    "the marking follows the cursor")
highlighted:onGotoPage(2)
check(highlighted.layout[1][1]._lardo_focused == true,
    "and the first row of a new page is marked right away")

--== the font settings are global, not per recipe =========================
plugin.settings:saveSetting("font_size", 28)
plugin.settings:saveSetting("font_face", "/fonts/Beta-Bold.ttf")
local other_instance = Lardo:new{ ui = {} } -- as if the reader had loaded us too
check(other_instance.settings:readSetting("font_size") == 28,
    "another plugin instance sees the same font size",
    other_instance.settings:readSetting("font_size"))
check(other_instance.settings == plugin.settings,
    "both instances share one settings object, so neither can clobber the other")

-- they share the cache object, but not the tables they read out of it: a
-- refresh done in the file manager has to show in the reader's copy too
plugin.cache:saveSetting("list", { { slug = "from-the-other-one", name = "Fresh",
    updated_at = "t1", description = "" } })
other_instance.list = {}
other_instance:showBrowser()
check(other_instance.list[1] and other_instance.list[1].slug == "from-the-other-one",
    "opening the list re-reads what the other instance refreshed",
    other_instance.list[1] and other_instance.list[1].slug)
other_instance.browser:onCloseAllMenus()
UIManager.ticks = {}
plugin.cache:saveSetting("list", plugin.list)

other_instance.list = plugin.list
other_instance.current_list = plugin.current_list
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t4",recipeInstructions={{text="B4"}}}' } }
other_instance.viewer = nil
other_instance:showRecipeAt(1)
check(other_instance.viewer.font_size == 28, "and a recipe opened there uses them",
    other_instance.viewer.font_size)
check(other_instance.viewer.font_face == "/fonts/Beta-Bold.ttf", "typeface too")
UIManager.ticks = {}

--== language ============================================================
local LardoLang = require("lardolang")
plugin.settings:saveSetting("language", nil)
G_reader_settings:saveSetting("language", "pl_PL")
check(plugin:getLanguage() == "pl-PL", "falls back to KOReader's language", plugin:getLanguage())
plugin:applyLanguage()
check(LardoLang.t("ingredients") == "Składniki", "wording follows it")

plugin.settings:saveSetting("language", "de-DE")
plugin:applyLanguage()
check(plugin:getApi().language == "de-DE", "the API client carries the language")
next_responses = { { code = 200, body = '{items={},total=0,total_pages=1}' } }
plugin:getApi():getRecipeList()
check(last_request.headers["Accept-Language"] == "de-DE",
    "Mealie is told which language to answer in",
    tostring(last_request.headers["Accept-Language"]))

local language_menu = plugin:getLanguageMenuTable()
local polish = findItem(language_menu, "Polski")
check(polish ~= nil, "the language menu lists Polish")
check(polish.checked_func() == false, "German is selected, not Polish")
polish.callback()
check(plugin.settings:readSetting("language") == "pl-PL", "picking a language stores its Mealie tag")
check(readConf():find("language = pl%-PL") ~= nil, "and writes it to lardo.conf", readConf())
check(LardoLang.t("ingredients") == "Składniki", "and applies it immediately")
os.remove(conf_path)

-- "Follow KOReader" has to name KOReader's language, not the one in force here
plugin.settings:saveSetting("language", "pl-PL")
G_reader_settings:saveSetting("language", "en_US")
plugin:applyLanguage()
local follow_item = plugin:getLanguageMenuTable()[1]
check(follow_item.text_func():find("(English)", 1, true) ~= nil,
    "\"Follow KOReader\" names KOReader's own language, not the one we are in",
    follow_item.text_func())
check(#plugin:getLanguageMenuTable() == 3,
    "the language menu offers that, English and Polish, and nothing else",
    #plugin:getLanguageMenuTable())

--== the plugin's own interface is translated too ==========================
-- KOReader's gettext only knows KOReader's strings, so the menus stayed English
plugin:applyLanguage() -- pl-PL, set just above
local pl_menu = {}
plugin:addToMainMenu(pl_menu)
check(pl_menu.lardo.text_func() == "Lardo", "the menu entry is translated",
    pl_menu.lardo.text_func())
check(findItem(pl_menu.lardo.sub_item_table, "Przeglądaj przepisy") ~= nil, "and its items")
check(findItem(plugin:getFontMenuTable(), "Krój pisma: Beta-Bold") ~= nil,
    "including the view settings, values and all")
check(findItem(plugin:getConnectionMenuTable(), "Sprawdź połączenie") ~= nil,
    "and the connection settings")

local N_pl = require("lardoi18n").ngettext
local function plRecipes(n)
    return N_pl("%1 recipe in Mealie", "%1 recipes in Mealie", n)
end
check(plRecipes(1) == "%1 przepis w Mealie", "Polish singular", plRecipes(1))
check(plRecipes(3) == "%1 przepisy w Mealie", "Polish 2-4 form", plRecipes(3))
check(plRecipes(5) == "%1 przepisów w Mealie", "Polish 5+ form", plRecipes(5))
check(plRecipes(13) == "%1 przepisów w Mealie", "13 is not 3")
check(plRecipes(22) == "%1 przepisy w Mealie", "but 22 is", plRecipes(22))
check(N_pl("%1 thing", "%1 things", 2) == "%1 things",
    "an untranslated plural falls back to KOReader's gettext")

plugin.settings:saveSetting("language", "en-US")
plugin:applyLanguage()
check(findItem(plugin:getFontMenuTable(), "Typeface: Beta-Bold") ~= nil,
    "switching back returns the menus to English")

--== the recipe list is read in the same font as the recipes ===============
plugin.settings:saveSetting("font_face", "/fonts/Alpha-Regular.ttf")
plugin.settings:saveSetting("font_size", 24)
plugin.browser = nil
plugin:showBrowser()
UIManager.ticks = {}
local browser = plugin.browser
check(browser.item_font_face == "/fonts/Alpha-Regular.ttf",
    "the list opens in the reading typeface", browser.item_font_face)
check(browser.items_font_size == 24, "and in its size", browser.items_font_size)
check(browser.layout[1][1].font == "/fonts/Alpha-Regular.ttf",
    "which is what the rows are drawn in", browser.layout[1][1].font)
local rows_at_24 = browser.items_per_page

-- the list sits behind the open recipe, so a change there has to reach it
plugin:applyViewSetting("font_size", 34, "font_size")
check(browser.items_font_size == 34, "a size picked while reading reaches the list",
    browser.items_font_size)
check(browser.items_per_page < rows_at_24,
    "with fewer rows per page, or Menu would cap the font back down",
    browser.items_per_page)
plugin:applyViewSetting("font_face", nil, "font_face")
check(browser.item_font_face == nil, "and so does resetting the typeface")
check(browser.layout[1][1].font == "smallinfofont",
    "which puts the rows back into the interface font", browser.layout[1][1].font)
-- the file manager is always underneath us; UIManager only skips painting it
-- if the widget on top says it covers the screen
check(browser.covers_fullscreen == true,
    "the list tells UIManager not to paint the file browser underneath it")
plugin.browser:onCloseAllMenus()

--== the recipe list has a row of buttons of its own =======================
-- There are no icons in the title bar any more: the ☰ moved down into the row,
-- where it is a button like the others, and the ✕ went with it.
local RecipeBrowser = require("lardobrowser")
check(RecipeBrowser.title_bar_left_icon == nil, "no menu icon in the title bar")

plugin:showBrowser()
local list = plugin.browser

-- The line of chrome has no icons in it at all: the ✕ Menu asks TitleBar for is
-- gone (it called onClose(), which on this list is the key that deliberately
-- does nothing, so it was a door painted on a wall), and the menu is a tap on
-- that line or the Menu key.
check(list.title_bar.right_button == nil, "no ✕ left in the title bar")
check(#list.title_bar == 0, "and nothing of it left to draw", #list.title_bar)
check(list.title_bar.has_right_icon == false,
    "TitleBar is told as much, or it would reach for the button again")
-- and it stays gone: `setTitle` re-runs the whole of TitleBar:init when the
-- title may change height (`title_shrink_font_to_fit`, which this list sets),
-- so a ✕ taken away without its `close_callback` comes back with the next count
-- in that line -- which is every refresh, and every letter typed into a filter
list:switchItemTable("9 recipes in Mealie", list.item_table, 1)
check(list.title_bar.right_button == nil and #list.title_bar == 0,
    "and a new count in that line does not bring it back", #list.title_bar)
check(list.title_bar.close_callback == nil,
    "because what built it is gone, not just the button")

-- the reading typeface reaches the rows of the list, and nothing else in the
-- grid: Font wants a size with it, and only Menu's own rows carry one
plugin.settings:saveSetting("font_face", "/fonts/Alpha-Regular.ttf")
plugin.browser = nil
plugin:showBrowser()
list = plugin.browser
check(list.layout[1][1].font == "/fonts/Alpha-Regular.ttf",
    "the recipes are drawn in it", list.layout[1][1].font)
plugin:applyViewSetting("font_face", nil, "font_face")
plugin.browser:onCloseAllMenus()

--== every menu is a list of values, and opens what can be changed ========
-- "Reading position bar: Under the chapters" is the pattern: an entry that only
-- gives its own name makes you open it to find out where things stand.
plugin.settings:saveSetting("url", "http://mealie.lan:9000")
plugin.settings:saveSetting("font_size", 24)
plugin:showBrowser()
-- Robust on purpose: when something is wrong it is handed whatever widget was
-- left on the stack, and a check that fails should say so rather than crash.
local function dialogLabels(dialog)
    local labels = {}
    local rows = (type(dialog) == "table" and dialog.buttons) or {}
    for i = 1, #rows do
        local row = rows[i] or {}
        for j = 1, #row do
            labels[#labels + 1] = row[j] and row[j].text
        end
    end
    return labels
end
-- The Menu button opens KOReader's own menu: there is no second menu of ours
-- to keep in step with it, and the settings were never ours to keep twice.
local ko_menu_shown = 0
-- KOReader's menu, as v2026.07.1 behaves -- read off its sources, because every
-- shortcut here has cost us a device that would not come up.
--
-- The skeleton (the row of tabs, and one entry per tab carrying its icon) is
-- built once, in FileManagerMenu:init(). `MenuSorter:sort` then *eats* the flat
-- table: it can only place a tab it still finds in it, it removes what it
-- places, and it drops `KOMenu:menu_buttons` last of all. Nothing puts that
-- back (newer KOReaders re-create it at the top of setUpdateItemTable), so a
-- second build has no row of tabs and dies exactly where the user's did.
local menu_order = require("ui/elements/filemanager_menu_order")
local function newKOReaderMenu()
    return {
        builds = 0,
        menu_items = {
            ["KOMenu:menu_buttons"] = {},
            filemanager_settings = { icon = "appbar.filebrowser" },
            setting = { icon = "appbar.settings" },
            tools = { icon = "appbar.tools" },
            search = { icon = "appbar.search" },
            main = { icon = "appbar.menu" },
        },
        -- `settings/<prefix>_menu_order.lua`, which a menu customiser writes.
        -- MenuSorter:mergeAndSort copies it over the order module -- *after*
        -- every plugin has had its say -- so anything a plugin put in the row
        -- while building is gone by the time the row is read.
        user_order = nil,
        setUpdateItemTable = function(this)
            this.builds = this.builds + 1
            -- KOReader's own entries are rebuilt on every build; the one that
            -- matters here is the section every contributed plugin hangs off
            this.menu_items.more_tools = { text = "More tools" }
            plugin:addToMainMenu(this.menu_items)
            local order = {}
            for id, entry in pairs(menu_order) do order[id] = entry end
            for id, entry in pairs(this.user_order or {}) do order[id] = entry end
            local items = this.menu_items
            local row = items["KOMenu:menu_buttons"]
            if row then -- menusorter.lua:54, which skips what is not there...
                for _, id in ipairs(order["KOMenu:menu_buttons"]) do
                    if items[id] then
                        table.insert(row, { id = id, icon = items[id].icon })
                    end
                end
            end
            local tabs = {}
            -- ...and menusorter.lua:139, which does not: with the row gone this
            -- is "bad argument #1 to 'ipairs' (table expected, got nil)"
            -- A list in the order whose id is itself a list is a sub-menu --
            -- `tools` ends with `more_tools`, which is where the plugins are.
            local function section(ids, depth)
                local built = {}
                for _, id in ipairs(ids or {}) do
                    local item = items[id]
                    if item then
                        item.id = id
                        if order[id] and depth < 4 then
                            item.sub_item_table = section(order[id], depth + 1)
                        end
                        table.insert(built, item)
                        items[id] = nil -- consumed
                    end
                end
                return built
            end
            for i, tab in ipairs(row) do
                tabs[i] = { id = tab.id, icon = tab.icon,
                    sub_item_table = section(order[tab.id], 1) }
                items[tab.id] = nil -- consumed
            end
            items["KOMenu:menu_buttons"] = nil -- consumed, last of all
            -- and an id the order file disables is *deleted*, before orphan
            -- handling ever sees it: gone from the menu without a trace
            for _, id in ipairs(order["KOMenu:disabled"] or {}) do
                items[id] = nil
            end
            -- Everything still in the flat table is an orphan, and an orphan
            -- with a `sorting_hint` goes into that tab -- which is how a plugin
            -- entry reaches Tools without being listed in the order, ours
            -- included. `new` is the real one's mark against doing it twice to
            -- the same table: an entry kept from one build to the next is
            -- silently dropped by the sorter on the second.
            for id, item in pairs(items) do
                if type(item) == "table" and item.text and item.new ~= true then
                    item.id, item.new = id, true
                    -- no hint: into the first tab, with a prefix that says the
                    -- sorter did not know where to put it
                    if not item.sorting_hint then item.text = "NEW: " .. item.text end
                    -- an orphan that had children placed into it by the order
                    -- keeps them, as its own sub-menu
                    if #item > 0 then
                        item.sub_item_table = {}
                        for i = 1, #item do item.sub_item_table[i] = item[i] end
                    end
                    local target = tabs[1]
                    for _, tab in ipairs(tabs) do
                        if tab.id == item.sorting_hint then target = tab end
                    end
                    if target then table.insert(target.sub_item_table, item) end
                end
            end
            this.tab_item_table = tabs
        end,
        onShowMenu = function(this, index)
            ko_menu_shown = ko_menu_shown + 1
            this.shown_index = index
            if this.tab_item_table == nil then this:setUpdateItemTable() end
        end,
    }
end
-- Lardo can be in three places: a tab of its own, an entry in Tools, or one in
-- More tools inside it -- and, when the sorter did not know where to put it, an
-- orphan with a "NEW: " prefix wherever it was swept. Say which.
-- @return the path to it, and the item itself
local function whereIsLardo(menu)
    local function walk(items, trail, depth)
        for _, item in ipairs(items or {}) do
            if type(item) == "table" then
                if item.id == "lardo" then
                    return (item.text == "NEW: Lardo" and "orphaned into " or "") .. trail, item
                end
                if depth < 4 then
                    local found, it = walk(item.sub_item_table,
                        trail .. "/" .. tostring(item.id), depth + 1)
                    if found then return found, it end
                end
            end
        end
    end
    for _, tab in ipairs(menu.tab_item_table or {}) do
        if tab.id == "lardo" then return "a tab", tab end
        local found, item = walk(tab.sub_item_table, tostring(tab.id), 1)
        if found then return found, item end
    end
    return nil -- one value, so a caller can tostring() the answer
end
local fake_ko_menu = newKOReaderMenu()
plugin.ui = { menu = fake_ko_menu }
fake_ko_menu:setUpdateItemTable() -- KOReader builds it once, on the way in
plugin:showKOReaderMenu()
check(ko_menu_shown == 1, "the Menu button opens KOReader's menu", ko_menu_shown)
check(fake_ko_menu.builds == 1,
    "without asking it to build the menu again, which is what crashed it")
check(#fake_ko_menu.tab_item_table == 5, "and the tabs it built are still there",
    #fake_ko_menu.tab_item_table)

-- a language change does need a rebuild, and a rebuild needs the skeleton the
-- sort ate: KOReader does not put it back, so we do
plugin:dropMenuCache()
check(fake_ko_menu.tab_item_table == nil, "a language change drops the sorted menu")
check(type(fake_ko_menu.menu_items["KOMenu:menu_buttons"]) == "table",
    "and hands back the row of tabs the sort had taken away")
local rebuilt_ok, rebuild_err = pcall(function() fake_ko_menu:onShowMenu() end)
check(rebuilt_ok, "so the build that follows works at all", tostring(rebuild_err))
check(rebuilt_ok and #fake_ko_menu.tab_item_table == 5,
    "with every one of KOReader's own tabs back in the row")

local menu_items = plugin:menuItemsToTouchMenu(plugin:getMenuItems())
local function itemStartingWith(items, prefix)
    for i = 1, #items do
        local label = items[i].text_func and items[i].text_func() or items[i].text
        if tostring(label):sub(1, #prefix) == prefix then return items[i] end
    end
end

-- everything the popup used to hold is in it, including the doors
check(itemStartingWith(menu_items, "Filter: ") ~= nil, "the filter is in it",
    table.concat(allMenuLabels(), " | "))
check(itemStartingWith(menu_items, "Sort by: ") ~= nil, "and the sort order")
check(itemStartingWith(menu_items, "Refresh (last: ") ~= nil, "and the refresh")
check(itemStartingWith(menu_items, "Back to the list") ~= nil, "and the way back out of a recipe")
check(itemStartingWith(menu_items, "Close Lardo") ~= nil, "and the way out of Lardo")
check(itemStartingWith(menu_items, "Screen") ~= nil and itemStartingWith(menu_items, "Connection") ~= nil
    and itemStartingWith(menu_items, "Application settings") ~= nil,
    "with the settings behind the same three categories")

-- an entry that takes you somewhere closes the menu behind it: pressing Filter
-- should leave you in the filter box, not in the box with the menu on top
local function keepsMenuOpen(prefix)
    return itemStartingWith(menu_items, prefix).keep_menu_open == true
end
check(keepsMenuOpen("Filter: ") == false, "the filter closes the menu behind it")
check(keepsMenuOpen("Browse recipes") == false, "and so does opening the list")
check(keepsMenuOpen("Back to the list") == false, "and leaving a recipe")
check(keepsMenuOpen("Close Lardo") == false, "and leaving Lardo")
check(keepsMenuOpen("Refresh (last: ") == false,
    "and refreshing, which is done to see the list afterwards")
check(keepsMenuOpen("Clear the filter") == false, "and clearing the filter")
local app_level = itemStartingWith(menu_items, "Application settings").sub_item_table
check(itemStartingWith(app_level, "Open Lardo instead").keep_menu_open == true,
    "and a switch stays where it is")

-- an entry that needs a screen of ours is disabled rather than missing: a menu
-- whose entries move around is harder to learn than one whose entries grey out
plugin.viewer = nil
check(itemStartingWith(menu_items, "Back to the list").enabled_func() == false,
    "nothing to go back to, so it is grey")
plugin.viewer = { onClose = function() end }
check(itemStartingWith(menu_items, "Back to the list").enabled_func() == true,
    "and live once a recipe is open")
plugin.viewer = nil

local connection = itemStartingWith(menu_items, "Connection").sub_item_table
check(itemStartingWith(connection, "Server address: http://mealie.lan:9000") ~= nil,
    "the server is one level in, where it is set",
    table.concat(dialogLabels({ buttons = {} }), ""))
local screen_level = itemStartingWith(menu_items, "Screen").sub_item_table
check(itemStartingWith(screen_level, "Fonts: 24 pt") ~= nil, "the fonts say what they are set to")
check(itemStartingWith(screen_level, "Keep the recipe on screen: ") ~= nil,
    "and so does what keeps the screen awake, wherever the menu was opened from")

--== a tab of our own in KOReader's menu ==================================
-- KOReader's menu is a row of tabs with an icon each, and the row is a table
-- `require` hands out -- so a plugin can add one. Off by default: it is
-- somebody else's menu.
local menu_order = require("ui/elements/filemanager_menu_order")
local tab_items = {}
plugin.settings:saveSetting("own_menu_tab", nil)
plugin:addToMainMenu(tab_items)
check(tab_items.lardo ~= nil and tab_items.lardo.sorting_hint == "tools",
    "off: one entry under Tools, the way plugins usually sit")
check(tab_items.lardo.icon == nil, "and no tab icon")
local in_row = false
for i = 1, #menu_order["KOMenu:menu_buttons"] do
    if menu_order["KOMenu:menu_buttons"][i] == "lardo" then in_row = true end
end
check(in_row == false, "and nothing added to KOReader's row of tabs")

plugin.settings:saveSetting("own_menu_tab", true)
tab_items = {}
plugin:addToMainMenu(tab_items)
check(tab_items.lardo ~= nil and tab_items.lardo.icon ~= nil,
    "on: a tab with an icon of its own", tab_items.lardo and tab_items.lardo.icon)
check(tab_items.lardo.sub_item_table == nil,
    "whose contents come from the order, not from a sub_item_table")
check(type(menu_order.lardo) == "table" and #menu_order.lardo > 3,
    "which lists our entries by id", menu_order.lardo and #menu_order.lardo)
check(tab_items[menu_order.lardo[1]] ~= nil, "and every one of those ids is published",
    menu_order.lardo[1])
check(menu_order["KOMenu:menu_buttons"][#menu_order["KOMenu:menu_buttons"]] == "lardo",
    "the tab goes at the end of the row, so KOReader's own tab indices do not shift",
    table.concat(menu_order["KOMenu:menu_buttons"], " "))

-- and the menu opens straight into it
local opened_tab
local tabbed_menu = {
    tab_item_table = { { id = "tools" }, { id = "lardo" } },
    onShowMenu = function(_self, tab_index) opened_tab = tab_index end,
}
plugin.ui = { menu = tabbed_menu }
plugin:showKOReaderMenu()
check(opened_tab == 2, "pressing Menu lands on our tab rather than three presses away",
    tostring(opened_tab))

-- switched off again, the row is left as it was found
plugin.settings:saveSetting("own_menu_tab", nil)
tab_items = {}
plugin:addToMainMenu(tab_items)
in_row = false
for i = 1, #menu_order["KOMenu:menu_buttons"] do
    if menu_order["KOMenu:menu_buttons"][i] == "lardo" then in_row = true end
end
check(in_row == false, "the tab is taken back out of a row that is not ours",
    table.concat(menu_order["KOMenu:menu_buttons"], " "))
check(menu_order.lardo == nil, "and so is what it listed")

-- ...and the whole way through, which is the only way it is ever used. A tab is
-- a change to the row of tabs, so it appears only once KOReader has built its
-- menu again -- and that build is exactly what used to die, with the tab never
-- appearing and the menu unopenable for the rest of the session.
plugin.settings:saveSetting("own_menu_tab", nil)
local tabbing_menu = newKOReaderMenu()
plugin.ui = { menu = tabbing_menu }
tabbing_menu:setUpdateItemTable() -- the build KOReader does on the way in
local function ourTab(menu)
    for i = 1, #(menu.tab_item_table or {}) do
        if menu.tab_item_table[i].id == "lardo" then return menu.tab_item_table[i], i end
    end
end
check(ourTab(tabbing_menu) == nil, "no tab of ours until it is asked for")

local function pressOwnTabSwitch()
    local switch = findItemDeep(plugin:menuItemsToTouchMenu(plugin:getMenuItems()),
        "Own tab in KOReader's menu")
    check(switch ~= nil, "the switch for it is in the menu")
    switch.callback({ updateItems = function() end })
end
pressOwnTabSwitch()
local menu_ok, menu_err = pcall(function() plugin:showKOReaderMenu() end)
check(menu_ok, "switching it on and opening the menu again keeps the menu alive",
    tostring(menu_err))
local our_tab, at = ourTab(tabbing_menu)
check(our_tab ~= nil, "the tab is in the row now")
check(our_tab and our_tab.icon == "book.opened", "with an icon of its own",
    our_tab and tostring(our_tab.icon))
check(our_tab and #our_tab.sub_item_table > 3, "and our entries inside it",
    our_tab and #our_tab.sub_item_table)
check(tabbing_menu.shown_index == at, "and the menu opens straight into it",
    tostring(tabbing_menu.shown_index) .. " of " .. tostring(at))
check(#tabbing_menu.tab_item_table == 6,
    "next to every one of KOReader's own, which the rebuild had to hand back",
    #tabbing_menu.tab_item_table)



do
    -- KOReader asks each plugin for its entries inside a pcall of its own and, on a
    -- failure, logs "failed to register widget" and carries on -- so a throw in here
    -- does not crash anything, it takes Lardo out of KOReader's menu and says
    -- nothing. One entry that still opens the recipes beats a tidy menu that is not
    -- there at all.
    local real_get_menu_items = plugin.getMenuItems
    plugin.getMenuItems = function() error("this KOReader has moved something") end
    local hurt_menu = newKOReaderMenu()
    plugin.ui = { menu = hurt_menu }
    local survived = pcall(function() hurt_menu:setUpdateItemTable() end)
    check(survived, "a menu that cannot be built does not take KOReader's down with it")
    local place, door = whereIsLardo(hurt_menu)
    check(door ~= nil, "and Lardo is still in the menu", tostring(place))
    plugin.browser = nil
    if door then door.sub_item_table[1].callback() end
    check(plugin.browser ~= nil, "with a door that still opens the recipes")
    if plugin.browser then plugin.browser:onCloseAllMenus() end
    plugin.browser = nil
    plugin.getMenuItems = real_get_menu_items
    plugin.ui = { menu = tabbing_menu }
end

pressOwnTabSwitch() -- and off again
plugin:showKOReaderMenu()
check(ourTab(tabbing_menu) == nil, "switched off, the tab goes away")
check(#tabbing_menu.tab_item_table == 5, "leaving the row it was added to",
    #tabbing_menu.tab_item_table)
do
    -- Every contributed plugin announces itself to the menu *order* at load
    -- time (`ui/plugin/insert_menu`). That is what makes MenuSorter **place**
    -- it under Tools -> More tools rather than sweep it up as an orphan
    -- afterwards, and what a menu customiser -- which reads those orders -- can
    -- see at all. Lardo did not, which is why it was the one plugin missing
    -- from the menu on a device where the others were exactly where they should
    -- be.
    local function listed(order)
        for i = 1, #(order.more_tools or {}) do
            if order.more_tools[i] == "lardo" then return true end
        end
        return false
    end
    check(listed(menu_order), "the file manager's order lists Lardo under More tools")
    check(listed(require("ui/elements/reader_menu_order")),
        "and the reader's too, which insert_menu fills in with the same call")

    local free_switch = findItemDeep(plugin:menuItemsToTouchMenu(plugin:getMenuItems()),
        "Own tab in KOReader's menu")
    check(free_switch and free_switch.enabled_func and free_switch.enabled_func() == true,
        "with nothing fixing the row of tabs, that switch is there to be used")

    local placed = newKOReaderMenu()
    plugin.ui = { menu = placed }
    placed:setUpdateItemTable()
    check(whereIsLardo(placed) == "tools/more_tools",
        "so the very first build puts it where every other plugin is",
        tostring(whereIsLardo(placed)))

    -- one place or the other, never both: the sorter puts the contents in
    -- whichever it finds first and leaves an empty row behind in the other
    plugin.settings:saveSetting("own_menu_tab", true)
    local tabbed = newKOReaderMenu()
    plugin.ui = { menu = tabbed }
    tabbed:setUpdateItemTable()
    check(whereIsLardo(tabbed) == "a tab", "a tab of its own when that is asked for",
        tostring(whereIsLardo(tabbed)))
    check(listed(menu_order) == false, "and then no longer under More tools as well")
    plugin.settings:saveSetting("own_menu_tab", nil)

    -- The device this came from: a menu order file fixes the row of tabs and
    -- does not know us, so a tab cannot survive the sort -- and claiming one
    -- costs the entry under Tools, which is the only place left. That file is
    -- the one thing that can be read *before* the build, so read it.
    local order_path = test_dir .. "/koreader/settings/filemanager_menu_order.lua"
    local row = '{ "filemanager_settings", "setting", "tools", "search", "main" }'
    local order_file = io.open(order_path, "w")
    order_file:write('return { ["KOMenu:menu_buttons"] = ' .. row .. ' }\n')
    order_file:close()
    plugin.menu_order_file = order_path
    plugin.tab_survives = nil -- read once per plugin; this is a new device
    plugin.settings:saveSetting("own_menu_tab", true)
    local fixed = newKOReaderMenu()
    fixed.user_order = { ["KOMenu:menu_buttons"] = {
        "filemanager_settings", "setting", "tools", "search", "main" } }
    plugin.ui = { menu = fixed }
    fixed:setUpdateItemTable()
    check(whereIsLardo(fixed) == "tools/more_tools",
        "a tab that cannot survive is not claimed, and the entry stays where it is found",
        tostring(whereIsLardo(fixed)))
    check(fixed.builds == 1, "at the first build, with nothing opened first", fixed.builds)

    -- and nothing is said about it: we did not ask for a tab, so a menu
    -- without one is not news. The switch says it instead, by being greyed.
    UIManager.shown = {}
    plugin:showKOReaderMenu()
    check(#UIManager.shown == 0,
        "a tab never claimed is not reported as one that went missing",
        #UIManager.shown)
    local switch = findItemDeep(plugin:menuItemsToTouchMenu(plugin:getMenuItems()),
        "Own tab in KOReader's menu")
    check(switch and switch.enabled_func and switch.enabled_func() == false,
        "the switch for a tab that cannot be is greyed out, not tickable and inert")

    -- the answer comes off the disk, so it is read once rather than on every
    -- repaint of a menu that asks
    os.remove(order_path)
    check(plugin:tabWouldSurvive() == false,
        "and read once, not again for every menu that asks")

    plugin.settings:saveSetting("own_menu_tab", nil)
    plugin.menu_order_file = nil
    plugin.tab_survives = nil -- the answer belongs with the file it came from
    plugin.ui = { menu = fake_ko_menu }
end

do
    -- A menu customiser writes `settings/filemanager_menu_order.lua`, and
    -- `MenuSorter:mergeAndSort` copies that file over the order module *after*
    -- every plugin's addToMainMenu has run. So a row of tabs we added ourselves
    -- while building is gone by the time the row is read -- our tab can never
    -- appear, and because the tab path publishes no entry under Tools either,
    -- Lardo is nowhere in the menu at all. Which is what a Kindle with
    -- `menu_customizer` installed reported, while one without it was fine.
    local customised = newKOReaderMenu()
    customised.user_order = {
        ["KOMenu:menu_buttons"] = { -- the row as the customiser saved it: no us
            "filemanager_settings", "setting", "tools", "search", "main",
        },
    }
    plugin.ui = { menu = customised }
    plugin.settings:saveSetting("own_menu_tab", true)
    customised:setUpdateItemTable()
    check(whereIsLardo(customised) == "orphaned into filemanager_settings",
        "our tab is dropped, and what it published is swept into the first tab "
        .. "under a NEW: prefix -- reachable, and nowhere anyone would look",
        tostring(whereIsLardo(customised)))

    -- So the tab has to be checked *after* the build, which is the only moment
    -- anyone can tell, and given up on for the session when it did not take --
    -- and said out loud, because a switch that can be turned on and then does
    -- nothing, with nothing on the screen about it, is the worst of the three.
    UIManager.shown = {}
    plugin:showKOReaderMenu()
    local told = UIManager.shown[#UIManager.shown]
    check(told and told.text and told.text:find("could not be added", 1, true) ~= nil,
        "the tab it could not have is said out loud, not only logged",
        told and tostring(told.text))
    check(whereIsLardo(customised) == "tools/more_tools",
        "asked for the menu, Lardo gives the tab up and takes the entry it can have",
        tostring(whereIsLardo(customised)))
    check(plugin:usesOwnMenuTab() == true,
        "without unsetting what the user asked for -- another KOReader may allow it")
    local builds_before = customised.builds
    plugin:showKOReaderMenu()
    check(customised.builds == builds_before,
        "and it does not go round again on every press", customised.builds)

    plugin.settings:saveSetting("own_menu_tab", nil)
end

do
    -- The same file can also *hide* an id: `KOMenu:disabled`, which MenuSorter
    -- deletes from the flat table before orphan handling -- so it never lands
    -- anywhere and nothing is logged. Our entry and our tab share the id
    -- `lardo`, so one line in that file hides both, and Lardo is in neither
    -- Tools nor More tools while ticking the tab changes nothing either. That
    -- is somebody's own configuration, so we do not fight it -- we say so,
    -- once, and name the file it is in.
    plugin.settings:saveSetting("own_menu_tab", nil)
    local hidden = newKOReaderMenu()
    -- as the customiser writes it: a hidden id is left out of its section and
    -- listed as disabled, so it cannot come back as an orphan either
    hidden.user_order = {
        more_tools = { "plugin_management" },
        ["KOMenu:disabled"] = { "lardo" },
    }
    plugin.ui = { menu = hidden }
    hidden:setUpdateItemTable()
    check(whereIsLardo(hidden) == nil, "a disabled id leaves nothing behind in the menu",
        tostring(whereIsLardo(hidden)))

    -- with no such file we have no cause to name, and a guess is worse than
    -- silence: the log says it, the screen does not
    plugin.menu_order_file = test_dir .. "/koreader/settings/no_such_order.lua"
    UIManager.shown = {}
    plugin:showKOReaderMenu()
    check(#UIManager.shown == 0, "missing with no file to blame is said in the log alone",
        #UIManager.shown)

    local order_path = test_dir .. "/koreader/settings/filemanager_menu_order.lua"
    local order_file = io.open(order_path, "w")
    order_file:write('return { ["KOMenu:disabled"] = { "lardo" } }\n')
    order_file:close()
    plugin.menu_order_file = order_path
    UIManager.shown = {}
    plugin:showKOReaderMenu()
    local said = UIManager.shown[#UIManager.shown]
    check(said and said.text and said.text:find("filemanager_menu_order", 1, true) ~= nil,
        "Lardo says it is missing from the menu, and names the file that leaves it out",
        said and tostring(said.text))
    UIManager.shown = {}
    plugin:showKOReaderMenu()
    check(#UIManager.shown == 0, "and says it once, not on every press", #UIManager.shown)
    os.remove(order_path)
    plugin.menu_order_file = nil
end

plugin.settings:saveSetting("own_menu_tab", nil)
plugin.ui = { menu = fake_ko_menu }

--== KOReader's own menu presses every one of our buttons =================
-- It hands a callback its TouchMenu instance, where our dialogs hand a thing
-- that can be called. An entry that does `on_change()` on a TouchMenu instance
-- is an attempt to call a table -- which takes KOReader down with it, and did.
local tools_menu = plugin:menuItemsToTouchMenu(plugin:getMenuItems())
local fake_touchmenu = { updated = 0 }
fake_touchmenu.updateItems = function(this) this.updated = this.updated + 1 end
local pressed, broke = 0, {}
local function pressAll(items, depth)
    for i = 1, #items do
        local item = items[i]
        if item.text_func then item.text_func() end -- labels must not blow up either
        if item.enabled_func then item.enabled_func() end
        if item.checked_func then item.checked_func() end
        if item.callback then
            pressed = pressed + 1
            local ok, err = pcall(item.callback, fake_touchmenu)
            if not ok then table.insert(broke, tostring(err)) end
        end
        if item.sub_item_table and depth < 2 then pressAll(item.sub_item_table, depth + 1) end
    end
end
-- pressing everything changes everything, so put it all back afterwards
local saved_settings, saved_start_with = {}, G_reader_settings:readSetting("start_with")
for k, v in pairs(plugin.settings.data) do saved_settings[k] = v end

next_responses = { { code = 200, body = '{items={},total=0,total_pages=1}' } }
pressAll(tools_menu, 0)

for k in pairs(plugin.settings.data) do plugin.settings.data[k] = nil end
for k, v in pairs(saved_settings) do plugin.settings.data[k] = v end
G_reader_settings:saveSetting("start_with", saved_start_with)
plugin:applyLanguage()
check(pressed > 15, "every entry of the Tools menu, and a level below it, was pressed", pressed)

-- every row of it has something written on it: an entry whose label never
-- changes gives a plain `text`, and KOReader's menu draws that one
local blank = {}
local function findBlank(items, path)
    for i = 1, #items do
        local item = items[i]
        local label = item.text_func and item.text_func() or item.text
        if label == nil or label == "" then table.insert(blank, path .. "#" .. i) end
        if item.sub_item_table then findBlank(item.sub_item_table, path .. (label or "?") .. " > ") end
    end
end
findBlank(plugin:menuItemsToTouchMenu(plugin:getMenuItems()), "")
check(#blank == 0, "and every one of them has a label", table.concat(blank, ", "))
check(#broke == 0, "and none of them takes KOReader down", broke[1])
check(fake_touchmenu.updated > 0,
    "the ones that change something ask the menu to redraw itself", fake_touchmenu.updated)
if plugin.browser then plugin.browser:onCloseAllMenus() end
UIManager.shown = {}

--== a "book" in the library that opens Lardo =============================
-- KOReader's own mechanism for this: an auxiliary provider. FileManager asks
-- the registry who opens a file and, for one of those, calls
-- `self[provider]:openFile(file)` -- `self` being the file manager, `provider`
-- our plugin's name.
local DocumentRegistry = require("document/documentregistry")
check(DocumentRegistry.known_providers["lardo"] ~= nil,
    "the plugin registers itself as something that can open a file")
check(DocumentRegistry.filetype_provider["lardo"] == true,
    "and registers the file type it owns, which is what makes one visible")
-- KOReader builds a plugin again for every book opened and closed, while the
-- registry lives as long as KOReader does: registering on each of those would
-- grow the list it walks for every file in every folder.
local registered_types = #DocumentRegistry.providers
plugin:registerProvider()
plugin:registerProvider()
check(#DocumentRegistry.providers == registered_types,
    "once, however many times the plugin is started", #DocumentRegistry.providers)

-- FileManager:registerModule renames the instance the moment it registers it
-- ("filemanager" .. name), so self.name is not the key anything can be looked
-- up by once the plugin is running -- the file manager finds us by the name it
-- registered, and the registry by the one we registered.
local real_plugin_name = plugin.name
plugin.name = "filemanagerlardo"
check(plugin:isFileTypeSupported("/mnt/us/Recipes.lardo") == true,
    "it offers itself for its own shortcut")
check(plugin:isFileTypeSupported("/mnt/us/War and Peace.epub") == false,
    "and for nothing else, so the Open with dialog stays honest")

local shortcut_dir = test_dir .. "/library"
os.execute("mkdir -p '" .. shortcut_dir .. "'")
plugin.ui = { file_chooser = { path = shortcut_dir }, refreshed = 0 }
plugin.ui.onRefresh = function(this) this.refreshed = this.refreshed + 1 end
check(plugin:findShortcut() == nil, "no shortcut in a folder that has none")

local created = plugin:createShortcut()
check(created ~= nil and created:sub(1, #shortcut_dir) == shortcut_dir,
    "it is written into the folder on screen", tostring(created))
check(io.open(created) ~= nil, "and it is a real file, so the library can list it")
check(created:match("[^/]+$") == "Lardo.lardo", "named after the plugin it opens",
    created:match("[^/]+$"))

-- The question the file browser asks about every file it lists, with the
-- argument it really passes: a bare name, never a path. A shortcut that was
-- written, associated, and invisible all the same came down to this one call.
check(DocumentRegistry:hasProvider(created:match("[^/]+$")) == true,
    "and the browser will list it, which is the whole point of writing it")
check(DocumentRegistry:hasProvider("War and Peace.xyz") == false,
    "without laying claim to anything else")

-- ...and why saying only who we are never could: the filter skips a provider
-- that has an `order`, and an `order` is exactly what makes one auxiliary
local aux = DocumentRegistry:getProviderFromKey("lardo")
DocumentRegistry.filetype_provider["lardo"] = nil -- as if the type were not ours
DocumentRegistry:setProvider("Anything.lardo", aux, true)
check(DocumentRegistry:hasProvider("Anything.lardo") == false,
    "an association on its own leaves the file invisible, which is where this started")
DocumentRegistry.filetype_provider["lardo"] = true

-- a tap on it goes to us as a plugin, not to a document engine
local tapped = DocumentRegistry:getProvider(created, true)
check(tapped ~= nil and tapped.provider == "lardo" and tapped.order ~= nil,
    "and a tap on it reaches us, as an auxiliary provider",
    tapped and tostring(tapped.provider))
check(plugin.ui.refreshed == 1, "the folder on screen is listed again, or it would not show")
check(plugin:findShortcut() == created, "and it is found the next time we look")

plugin.browser = nil
plugin:openFile(created)
check(plugin.browser ~= nil, "opening it opens the recipe list")
plugin.browser:onCloseAllMenus()

-- and it can be put somewhere else, taking the file with it
local other_dir = test_dir .. "/library2"
os.execute("mkdir -p '" .. other_dir .. "'")
plugin:chooseShortcutDir()
local chooser = UIManager.shown[#UIManager.shown]
check(chooser.stub_name == "pathchooser", "the folder is picked, not typed",
    tostring(chooser.stub_name))
chooser:confirm(other_dir)
check(io.open(created) == nil, "the old one does not stay behind")
local moved = plugin:findShortcut()
check(moved ~= nil and moved:sub(1, #other_dir) == other_dir,
    "and it is where it was moved to", tostring(moved))
local purged = require("docsettings").purged
local purged_the_old_one = false
for i = 1, #purged do
    if purged[i] == created then purged_the_old_one = true end
end
check(purged_the_old_one,
    "and whatever sidecar an earlier version left beside it purged with it")

plugin:removeShortcut()
check(plugin:findShortcut() == nil, "and it can be taken away again")
plugin.settings:saveSetting("shortcut_dir", nil)
os.remove(created)
plugin.ui = nil
plugin.name = real_plugin_name

--== keeping the recipe on screen =========================================
-- A Kindle blanks the screen ten minutes after the last thing its firmware
-- counts as activity, and KOReader's input never reaches it. So say so.
local DevicePowerD = require("device").powerd
plugin.settings:saveSetting("keep_awake", nil)
plugin.settings:saveSetting("status_items", nil)
check(plugin:getKeepAwakeInterval() == 10, "ten minutes unless told otherwise",
    plugin:getKeepAwakeInterval())

-- Switching it on with nothing in the corner to show for it is a feature nobody
-- can tell is working: the recipe stays on the screen, which is what it does
-- anyway while you keep touching it. So the marker comes on with it.
do
    local function awakeShown() return plugin:getStatusItems().awake == true end
    local function pressInterval(label)
        local item = findItem(plugin:getKeepAwakeMenuTable(), label)
        check(item ~= nil, "the keep-awake menu offers " .. label)
        if item then item.callback() end
    end
    plugin.settings:saveSetting("keep_awake", 0)
    plugin.settings:saveSetting("status_items", { battery = true, awake = false })
    check(awakeShown() == false, "with the marker switched off and nothing kept awake")
    pressInterval("Every 10 minutes")
    check(awakeShown(), "switching it on brings its marker with it")

    -- ...but only then: turning the marker off while it runs is a decision
    plugin:toggleStatusItem("awake")
    check(awakeShown() == false, "the marker can still be taken away")
    pressInterval("Every 30 minutes")
    check(awakeShown() == false, "and changing the interval leaves that alone")
    plugin.settings:saveSetting("keep_awake", nil)
    plugin.settings:saveSetting("status_items", nil)
end

UIManager.scheduled = {}
DevicePowerD.t1_resets = 0
plugin.list = { Recipe.normalizeSummary({ slug = "b", name = "B", updatedAt = "t4" }) }
plugin:buildItemTable()
plugin.viewer = nil
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t4",recipeInstructions={{text="B4"}}}' } }
plugin:showRecipeAt(1)
check(DevicePowerD.t1_resets == 1, "opening a recipe says it straight away",
    DevicePowerD.t1_resets)
check(#UIManager.scheduled == 1, "and asks to say it again", #UIManager.scheduled)
check(UIManager.scheduled[1].seconds == 4 * 60,
    "on the device's clock, not on the one the corner is redrawn on: four minutes "
    .. "is KOReader's own figure, and lower than the shortest screensaver a Kindle has",
    UIManager.scheduled[1].seconds)
check(require("pluginshare").pause_auto_suspend == true,
    "KOReader's own sleep is held off too, or it would suspend under the recipe")

UIManager:runScheduled()
check(DevicePowerD.t1_resets == 2, "every tick says it again", DevicePowerD.t1_resets)
check(#UIManager.scheduled == 1, "and schedules the next one")

-- charging is the one time the reset causes trouble (KOReader's own AutoSuspend
-- skips it too), and a charging Kindle is not about to run its battery down
DevicePowerD.charging = true
UIManager:runScheduled()
check(DevicePowerD.t1_resets == 2, "nothing is poked while charging", DevicePowerD.t1_resets)
check(#UIManager.scheduled == 1, "but the ticking carries on")
plugin.status_drawn_at = nil -- as if the interval had come round
UIManager:runScheduled()
check(plugin.viewer.status_text == "+75%", "and a charging battery says so in the corner",
    plugin.viewer.status_text)
check(plugin.viewer.status_text:find("A", 1, true) == nil,
    "with nothing claiming the screen is being kept on, because it is not",
    plugin.viewer.status_text)
DevicePowerD.charging = false
plugin.status_drawn_at = nil -- and again
UIManager:runScheduled()

-- the corner of the header, and that it follows the device
check(plugin.viewer.status_text == "A  75%",
    "the battery is in the corner by default, and one letter for the timer that keeps it on",
    plugin.viewer.status_text)
DevicePowerD.capacity = 42
UIManager:runScheduled()
check(plugin.viewer.status_text == "A  75%",
    "a poke in between leaves the corner alone: an e-ink refresh every four minutes "
    .. "to move a clock by four minutes is more flicker than anybody wants",
    plugin.viewer.status_text)
plugin.status_drawn_at = nil -- the interval comes round
UIManager:runScheduled()
check(plugin.viewer.status_text == "A  42%", "and then it is brought up to date",
    plugin.viewer.status_text)
-- the corner is arranged in one window, not a dialog that closes and reopens on
-- every tick: the same SortWidget the button rows use. Opened the way a reader
-- opens it -- through KOReader's menu, which hands the entry its TouchMenu
-- instance, and that is half of what this is about.
local corner_menu = plugin:menuItemsToTouchMenu(plugin:getMenuItems())
local function findByLabel(items, prefix)
    for i = 1, #items do
        local label = items[i].text_func and items[i].text_func() or items[i].text or ""
        if tostring(label):sub(1, #prefix) == prefix then return items[i] end
        if items[i].sub_item_table then
            local found = findByLabel(items[i].sub_item_table, prefix)
            if found then return found end
        end
    end
end
local corner_entry = findByLabel(corner_menu, "Status in the corner:")
check(corner_entry ~= nil and corner_entry.sub_item_table ~= nil,
    "the corner is a level of its own in KOReader's menu")
local order_entry = findByLabel(corner_entry.sub_item_table, "Order…")
check(order_entry ~= nil, "with the order one window further")
order_entry.callback({ updateItems = function() end })
local corner = UIManager.shown[#UIManager.shown]
check(corner.stub_name == "sortwidget", "the corner is arranged in one window",
    tostring(corner.stub_name))
local corner_labels = {}
for i = 1, #corner.item_table do corner_labels[i] = corner.item_table[i].label end
check(table.concat(corner_labels, " ") == "awake battery clock wifi",
    "with everything it can show, in the order it shows it",
    table.concat(corner_labels, " "))
-- the window puts things in order and nothing else: what is switched on is
-- ticked in the menu, where the whole line is the target rather than a
-- checkbox the size of a fingernail
check(corner.item_table[1].checked_func == nil,
    "no checkboxes in the arranging window any more")
local clock_tick = findByLabel(corner_entry.sub_item_table, "Clock")
check(clock_tick ~= nil and clock_tick.checked_func() == false,
    "the clock is ticked in the menu, and is not ticked to begin with")
clock_tick.callback({ updateItems = function() end })
check(clock_tick.checked_func() == true, "and one press of its line switches it on")

corner:moveItem(3, 1)  -- clock dragged to the front
local shown_before_accept = #UIManager.shown
corner:accept()
-- SortWidget's tick keeps its window open while an item is picked up for
-- moving; reopening the menu we came from lands it on top of the window
check(#UIManager.shown == shown_before_accept,
    "accepting an arrangement does not open the menu over the window",
    #UIManager.shown .. " vs " .. shown_before_accept)
check(plugin.viewer.status_text:sub(1, 5) == os.date("%H:%M"),
    "what was dragged to the front is drawn first", plugin.viewer.status_text)
check(plugin.viewer.status_text:find("42%%") ~= nil, "and the rest keeps its place",
    plugin.viewer.status_text)

plugin:toggleStatusItem("battery")
check(plugin.viewer.status_text:find("42%%") == nil, "one can still be switched off on its own",
    plugin.viewer.status_text)

-- WiFi in the corner has to follow the radio, not the next tick: a refresh that
-- hangs it up afterwards used to leave the mark sitting there for ten minutes
plugin:toggleStatusItem("wifi")
NetworkMgr.wifi_on = true
plugin:refreshStatus()
check(plugin.viewer.status_text:find("WiFi", 1, true) ~= nil, "WiFi shows while it is on",
    plugin.viewer.status_text)
NetworkMgr.wifi_on = false
plugin:onNetworkDisconnected()
check(plugin.viewer.status_text:find("WiFi", 1, true) == nil,
    "and goes the moment KOReader says the radio is down", plugin.viewer.status_text)
NetworkMgr.wifi_on = true
plugin:onNetworkConnected()
check(plugin.viewer.status_text:find("WiFi", 1, true) ~= nil, "and comes back the same way")

-- the same after our own refresh, which is what hangs the radio up
NetworkMgr.wifi_on = false
next_responses = { { code = 200, body = '{items={},total=0,total_pages=1}' } }
plugin:refreshList()
check(plugin.viewer.status_text:find("WiFi", 1, true) == nil,
    "a finished refresh leaves nothing claiming WiFi is on", plugin.viewer.status_text)
NetworkMgr.wifi_on = true
plugin:toggleStatusItem("wifi")
plugin.settings:saveSetting("status_items", nil)
plugin.settings:saveSetting("status_order", nil)
plugin.viewer:setStatus(plugin:statusText())

-- closing the recipe puts the device back the way it was
plugin.viewer.close_callback()
check(#UIManager.scheduled == 0, "closing the recipe stops the nudging", #UIManager.scheduled)
check(require("pluginshare").pause_auto_suspend == false, "and hands sleep back to KOReader")
plugin.viewer = nil

-- switched off, the corner stops claiming otherwise
plugin.settings:saveSetting("keep_awake", 0)
check(plugin:statusText():find("A", 1, true) == nil,
    "nothing says the screen is kept on once it is not", plugin:statusText())
plugin.settings:saveSetting("keep_awake", nil)
check(plugin:statusText():find("A", 1, true) ~= nil, "and says it again when it is")

-- nothing is scheduled at all with it off
plugin.settings:saveSetting("keep_awake", 0)
UIManager.scheduled = {}
DevicePowerD.t1_resets = 0
next_responses = { { code = 200, body = '{slug="b",name="B",updatedAt="t4",recipeInstructions={{text="B4"}}}' } }
plugin:showRecipeAt(1)
check(#UIManager.scheduled == 0 and DevicePowerD.t1_resets == 0,
    "turned off, a recipe is left to fall asleep like anything else")
plugin.viewer.close_callback()
plugin.viewer = nil
plugin.settings:saveSetting("keep_awake", nil)

-- and it is offered where a recipe can be open, not on the list
check(hasLabel(allMenuLabels(), "Keep the recipe on screen: ") ~= nil,
    "the menu offers it, under Screen")
check(hasLabel(allMenuLabels(), "Status in the corner: Awake, Battery") ~= nil,
    "along with what the corner shows",
    hasLabel(allMenuLabels(), "Status in the corner: "))

--== a KOReader without SortWidget cannot arrange, and says so ============
local real_sortwidget = package.loaded["ui/widget/sortwidget"]
package.loaded["ui/widget/sortwidget"] = nil
package.preload["ui/widget/sortwidget"] = function() error("no such widget") end
local order_in_menu = findByLabel(
    plugin:menuItemsToTouchMenu(plugin:getMenuItems()), "Order…")
check(order_in_menu.enabled_func() == false, "without it, the Order entry is grey")
plugin:showStatusSortDialog()
local fallback = UIManager.shown[#UIManager.shown]
check(fallback.stub_name == "infomessage", "and pressing it anyway says why",
    tostring(fallback.stub_name))
package.preload["ui/widget/sortwidget"] = nil
package.loaded["ui/widget/sortwidget"] = real_sortwidget

--== one menu, and it is KOReader's ========================================
local list_labels = allMenuLabels()
-- the top level is what is used while cooking, plus three categories
local top_list = menuLabels()
check(hasLabel(top_list, "Screen") ~= nil and hasLabel(top_list, "Connection") ~= nil
    and hasLabel(top_list, "Application settings") ~= nil,
    "the settings are behind three categories, named and nothing more",
    table.concat(top_list, " | "))
check(hasLabel(top_list, "Fonts: ") == nil, "so the top level is not a list of everything")
check(hasLabel(top_list, "Filter: ") ~= nil and hasLabel(top_list, "Refresh (last: ") ~= nil
    and hasLabel(top_list, "Close Lardo") ~= nil,
    "what is used while cooking stays one press away")
check(hasLabel(list_labels, "Back to the list") ~= nil, "a recipe is left through it")
check(hasLabel(list_labels, "Browse recipes") ~= nil, "and the list is opened through it")
for _i, label in ipairs({ "Fonts: ", "Offline: ", "Language: ", "Shortcut in the library: " }) do -- luacheck: ignore _i
    check(hasLabel(list_labels, label) ~= nil, "and every setting is in it: " .. label)
end

-- and the levels below are the same items KOReader's own menu is built from
local function findEntry(items, title)
    for i = 1, #items do
        if items[i].title == title then return items[i] end
        if items[i].sub_items then
            local found = findEntry(items[i].sub_items(), title)
            if found then return found end
        end
    end
end
local fonts_entry = findEntry(plugin:getMenuItems(), "Fonts")
check(fonts_entry ~= nil and fonts_entry.sub_items ~= nil, "the fonts are a level, not a dialog")
local font_items = fonts_entry.sub_items()
check(font_items[1].text_func() == "Size: 24", "with the size in it", font_items[1].text_func())
check(font_items[2].text_func():sub(1, 9) == "Typeface:", "and the typeface")

--== what the button rows left behind goes out with them ===================
-- Settings nothing reads are the settings-file version of dead code.
plugin.settings:saveSetting("list_buttons_position", "bottom")
plugin.settings:saveSetting("view_buttons", { menu = false })
plugin.settings:saveSetting("show_buttons", true)
plugin.settings = nil -- as if this were the next start-up
plugin:loadSettings()
check(plugin.settings:readSetting("list_buttons_position") == nil
    and plugin.settings:readSetting("view_buttons") == nil
    and plugin.settings:readSetting("show_buttons") == nil,
    "the settings the rows used are cleared on the way in")
check(plugin.settings:readSetting("font_size") ~= nil,
    "and nothing else is touched on the way past")

--== the 5-way walks the list, and off the edge of it ======================
plugin.list = {}
for i = 1, 12 do
    plugin.list[i] = Recipe.normalizeSummary({ slug = "k" .. i, name = "Keyboard " .. i, updatedAt = "t1" })
end
plugin.cache:saveSetting("list", plugin.list) -- showBrowser re-reads it from there
plugin:buildItemTable()
plugin.browser = nil
plugin:showBrowser()
local keyboard_list = plugin.browser
check(keyboard_list.ges_events.LardoHeaderTap == nil,
    "a device with no touch screen is not given a tap zone to miss")

-- every row of the grid is a recipe, and walking off it turns the page:
-- KOReader's Menu wraps the focus inside the page instead, which on a list of
-- three hundred recipes never leaves the first one
local rows_of_recipes = math.min(keyboard_list.perpage, #keyboard_list.item_table)
check(#keyboard_list.layout == rows_of_recipes,
    "the grid is the recipes on the page, and nothing else",
    #keyboard_list.layout .. " vs " .. rows_of_recipes)
keyboard_list.page = 1
local page_before = keyboard_list.page
keyboard_list.selected.y = #keyboard_list.layout
keyboard_list:onFocusMove({ 0, 1 })
check(keyboard_list.page == page_before + 1, "Down from the last recipe turns the page",
    keyboard_list.page)
keyboard_list:onFocusMove({ 0, -1 })
check(keyboard_list.page == page_before and keyboard_list.selected.y == #keyboard_list.layout,
    "and paging back lands on the last recipe of the page before",
    keyboard_list.page .. "/" .. keyboard_list.selected.y)
plugin.browser:onCloseAllMenus()

--== the list opens even when Menu's furniture is not where we left it =====
-- At start-up this is the screen: a plugin reaching into another version's
-- widget internals must not be the reason a device does not come up.
local RecipeBrowserModule = require("lardobrowser")
local real_remove = RecipeBrowserModule.removeTitleBarCloseButton
RecipeBrowserModule.removeTitleBarCloseButton = function()
    error("this KOReader keeps its title bar elsewhere")
end
plugin.browser = nil
local opened = pcall(function() plugin:showBrowser() end)
check(opened and plugin.browser ~= nil,
    "the recipe list opens with one stray icon on it, rather than not at all")
RecipeBrowserModule.removeTitleBarCloseButton = real_remove
plugin.browser:onCloseAllMenus()

--== a suspend must not rewrite the recipe cache ===========================
-- KOReader broadcasts FlushSettings before every suspend (every screensaver),
-- and LuaSettings:flush() always rewrites the whole file -- for us, every
-- recipe on the device.
plugin:onFlushSettings() -- whatever the tests above left pending, written once
plugin.cache.flushes = 0
plugin:onFlushSettings()
plugin:onFlushSettings()
check(plugin.cache.flushes == 0, "nothing changed, nothing written", plugin.cache.flushes)
plugin.cache:saveSetting("list", plugin.list)
plugin:onFlushSettings()
check(plugin.cache.flushes == 1, "a real change is still written", plugin.cache.flushes)
plugin:onFlushSettings()
check(plugin.cache.flushes == 1, "and only once, however often KOReader asks",
    plugin.cache.flushes)

--== WiFi is handed back once the downloading is done ======================
-- NetworkMgr:runWhenOnline() only brings the connection up; "Action when done"
-- happens in afterWifiAction(), and only if we call it
local NetworkMgr = require("ui/network/manager")
plugin.settings:saveSetting("url", "http://mealie.lan:9000")
plugin.settings:saveSetting("token", "tok")
NetworkMgr.after_action_count = 0
next_responses = { { code = 200, body = '{items={{slug="pancakes",name="Pancakes",updatedAt="t1"}},total=1,total_pages=1}' } }
plugin:refreshList()
check(NetworkMgr.after_action_count == 1,
    "a list refresh hands WiFi back to KOReader's setting", NetworkMgr.after_action_count)

NetworkMgr.after_action_count = 0
next_responses = { { code = 500, status = "500 Internal Server Error" } }
plugin:refreshList()
check(NetworkMgr.after_action_count == 1,
    "and so does a failed one, or the radio would stay on", NetworkMgr.after_action_count)

-- A connection that went away mid-sync (the usual reason: the device fell
-- asleep) must not be retried once per remaining recipe -- every one of those
-- blocks for the socket timeout with KOReader waiting on it.
plugin:forgetAllRecipes()
request_count = 0
next_responses = {
    { code = 200, body = '{items={{slug="a",name="A",updatedAt="t1"},{slug="b",name="B",updatedAt="t1"},' ..
        '{slug="c",name="C",updatedAt="t1"},{slug="d",name="D",updatedAt="t1"},' ..
        '{slug="e",name="E",updatedAt="t1"},{slug="f",name="F",updatedAt="t1"}},total=6,total_pages=1}' },
}
for _i = 1, 6 do -- luacheck: ignore _i
    table.insert(next_responses, { code = 200, body = nil, status = "timeout" })
end
plugin:refreshList()
check(request_count == 4, "the sync gives up after three failures in a row, not after all six",
    request_count)

-- "Test connection" is the one action that must run even when KOReader's own
-- check says we are not online: whether the server answers is the question it
-- was asked, not a reason to do nothing.
NetworkMgr.online = false
NetworkMgr.when_connected_count = 0
NetworkMgr.after_action_count = 0
request_count = 0
next_responses = { { code = 200, body = '{items={{slug="pancakes",name="Pancakes"}},total=1,total_pages=1}' } }
plugin:testConnection()
check(NetworkMgr.when_connected_count == 1,
    "test connection needs the link only, so the WiFi prompt is not skipped",
    NetworkMgr.when_connected_count)
check(request_count == 1, "and the server really is contacted", request_count)
check(NetworkMgr.after_action_count == 1,
    "and WiFi still goes back to KOReader's setting", NetworkMgr.after_action_count)
NetworkMgr.online = true

--== automatic offline sync ================================================
plugin:forgetAllRecipes()
plugin.settings:saveSetting("auto_sync", true)
NetworkMgr.after_action_count = 0
next_responses = {
    { code = 200, body = '{items={{slug="pancakes",name="Pancakes",updatedAt="t2"}},total=1,total_pages=1}' },
    { code = 200, body = '{slug="pancakes",name="Pancakes",updatedAt="t2",recipeInstructions={{text="Fry."}}}' },
}
plugin:refreshList()
check(plugin:getCachedRecipe("pancakes") ~= nil,
    "with the option on, a refresh also stores every recipe")
check(NetworkMgr.after_action_count == 1,
    "in the same WiFi session as the refresh", NetworkMgr.after_action_count)
plugin.settings:saveSetting("auto_sync", false)

--== the start-up download =================================================
UIManager.ticks = {}
plugin.settings:saveSetting("auto_refresh", false)
Lardo:new{}
check(#UIManager.ticks == 0, "without the option nothing is downloaded at start-up",
    #UIManager.ticks)
plugin.settings:saveSetting("auto_refresh", true)
Lardo:new{}
check(#UIManager.ticks == 1, "with it, one refresh is queued", #UIManager.ticks)
UIManager.ticks = {}
Lardo:new{} -- the reader loads the plugin a second time
check(#UIManager.ticks == 0, "once per KOReader run, not once per plugin instance",
    #UIManager.ticks)
plugin.settings:saveSetting("auto_refresh", false)
UIManager.ticks = {}

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
