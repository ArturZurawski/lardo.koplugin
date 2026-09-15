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
local toggle = findItem(menu_items.lardo.sub_item_table,
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
check(title == "Filter: pancake_   2/3", "and the filter box takes that same line", title)
check(#plugin.current_list == 2, "current_list follows the filter")

plugin.filter = "zzz"
items = plugin:buildItemTable()
check(#items == 1 and items[1].dim == true, "empty result shows a hint item")
check(items[1].recipe == nil, "hint item is not selectable")
plugin.filter = nil

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

-- buttons are opt-in and cost height
local button_view = LardoView:new{ chapters = viewChapters(), show_buttons = true }
check(button_view.button_table ~= nil, "button row built when asked for")
check(button_view.layout ~= nil, "buttons are reachable by the focus manager")
check(button_view.key_events.FocusLeft ~= nil, "Left/Right stay with the buttons")
check(button_view.key_events.LardoChapterNext == nil, "so they do not also switch chapters")
check(button_view.text_widget.lines_per_page < view.text_widget.lines_per_page,
    "the button row costs reading space")

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

local menu_opened = 0
touch_view.menu_callback = function() menu_opened = menu_opened + 1 end
touch_view:onLardoTap(nil, { pos = { x = 590, y = 5 } })
check(menu_opened == 1, "the right hand end of the header opens the menu", menu_opened)
touch_view:onLardoHold()
check(menu_opened == 2, "and so does a long press anywhere")

local closed = 0
touch_view.close_callback = function() closed = closed + 1 end
touch_view:onLardoTap(nil, { pos = { x = 100, y = 5 } })
check(closed == 1, "the rest of the header goes back to the list", closed)

-- and the button row, the only visible way around, starts out shown
plugin.settings:saveSetting("show_buttons", nil)
check(plugin:getShowButtons() == true, "a touch screen gets the button row by default")
DeviceStub.isTouchDevice = real_is_touch
check(plugin:getShowButtons() == false, "a keyboard device does not")
plugin.settings:saveSetting("show_buttons", true)
check(plugin:getShowButtons() == true, "and an explicit choice wins on either")
plugin.settings:saveSetting("show_buttons", nil)

local keys_only_view = LardoView:new{ chapters = viewChapters() }
check(keys_only_view.ges_events == nil or keys_only_view.ges_events.LardoTap == nil,
    "nothing is bound to taps where there is no touch screen")

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

check(findItem(plugin:getViewMenuTable(), "Simple text viewer: off") == nil,
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

local view_menu = plugin:getViewMenuTable()
local typeface_item = findItem(view_menu, "Typeface: Custom")
check(typeface_item ~= nil, "the menu shows the chosen typeface by name")
local reset_item = findItem(view_menu, "Use KOReader's default typeface")
check(reset_item.enabled_func() == true, "resetting is offered while a font is set")
reset_item.callback()
check(plugin.settings:readSetting("font_face") == nil, "typeface reset to the default")
check(findItem(plugin:getViewMenuTable(), "Typeface: KOReader default") ~= nil,
    "and the menu says so")

check(findItem(plugin:getViewMenuTable(), "Reading position bar: Right edge, whole recipe") ~= nil,
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
check(findItem(plugin:getViewMenuTable(), "Krój pisma: Beta-Bold") ~= nil,
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
check(findItem(plugin:getViewMenuTable(), "Typeface: Beta-Bold") ~= nil,
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
