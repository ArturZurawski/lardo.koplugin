-- Rough measurements for the things that happen while somebody is waiting:
-- opening the list, typing into it, opening a recipe, and what KOReader has to
-- parse at start-up. Run with: tests/bench.sh  (or LUA=... tests/bench.sh)
--
-- The numbers are from a development machine, so they are only useful next to
-- each other -- a Kindle Keyboard is roughly two orders of magnitude slower,
-- and its util.stringLower() is a real UTF-8 pass rather than the stub's
-- string.lower(), which makes the filtering difference larger there, not
-- smaller.
local here = (arg[0] or "tests/x"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/stub/?.lua;" .. here .. "/../lardo.koplugin/?.lua;" .. package.path

G_reader_settings = require("luasettings"):open("global")
package.loaded["socket.http"] = { request = function() return nil, "offline" end }
package.loaded["socket"] = { skip = function() end }
package.loaded["ltn12"] = { sink = { table = function() end }, source = { string = function() end } }
package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
package.loaded["json"] = { decode = function() return nil end }

local Lardo = require("main")
local Recipe = require("lardorecipe")
local dump = require("dump")
local util = require("util")

local test_dir = os.getenv("MEALIE_BENCH_DIR") or "/tmp/lardo-bench"
os.execute("rm -rf '" .. test_dir .. "' && mkdir -p '" .. test_dir .. "'")
Lardo.recipes_dir = test_dir .. "/recipes"

local RECIPES = tonumber(os.getenv("BENCH_RECIPES")) or 300

local function ms(seconds) return string.format("%8.3f ms", seconds * 1000) end
local function timed(times, fn)
    local start = os.clock()
    for _i = 1, times do fn() end -- luacheck: ignore _i
    return (os.clock() - start) / times
end
local function report(label, seconds, note)
    print(string.format("  %-46s %s%s", label, ms(seconds), note and ("   " .. note) or ""))
end

--== the material ==========================================================
local WORDS = { "pancakes", "borscht", "żurek", "cake", "soup", "bread", "pierogi",
    "carbonara", "risotto", "chili", "curry", "gulasz", "sernik", "naleśniki" }
local function rawSummary(i)
    return {
        slug = "recipe-" .. i,
        id = "id-" .. i,
        name = WORDS[(i % #WORDS) + 1] .. " " .. i,
        updatedAt = "2026-01-" .. string.format("%02d", (i % 28) + 1),
        dateAdded = "2025-06-" .. string.format("%02d", (i % 28) + 1),
        description = "A " .. WORDS[((i + 3) % #WORDS) + 1] .. " recipe with a description "
            .. "of about the length these things have in Mealie, which is a couple of lines.",
        totalTime = (10 + i % 50) .. " min",
    }
end
local function rawFull(i)
    local raw = rawSummary(i)
    raw.recipeIngredient = {}
    for n = 1, 12 do
        raw.recipeIngredient[n] = { display = n .. "00 g of ingredient number " .. n }
    end
    raw.recipeInstructions = {}
    for n = 1, 8 do
        raw.recipeInstructions[n] = { text = "Step " .. n .. ": " ..
            string.rep("do the thing carefully and then wait a little while. ", 4) }
    end
    return raw
end

local plugin = Lardo:new{}
local list = {}
for i = 1, RECIPES do list[i] = Recipe.normalizeSummary(rawSummary(i)) end
plugin.list = list
plugin:forgetAllRecipes()

print(string.format("Lardo bench -- %d recipes\n", RECIPES))

--== the recipe list =======================================================
print("recipe list")
local build = timed(20, function()
    plugin.sorted_source = nil -- as if the list had just been downloaded
    plugin:buildItemTable()
end)
report("first draw (sort + haystacks + rows)", build)

plugin:buildItemTable()
plugin.filter = "cak"
local typing = timed(50, function() plugin:buildItemTable() end)
report("one more letter typed into the filter", typing)

-- what that cost before the sorted list and the haystacks were kept
local function buildTheOldWay()
    local matching = {}
    local filter = util.stringLower(plugin.filter)
    for i = 1, #list do
        local recipe = list[i]
        local matches = util.stringLower(recipe.name):find(filter, 1, true) ~= nil
        if not matches and recipe.description ~= "" then
            matches = util.stringLower(recipe.description):find(filter, 1, true) ~= nil
        end
        if matches then matching[#matching + 1] = recipe end
    end
    table.sort(matching, function(a, b)
        return util.stringLower(a.name) < util.stringLower(b.name)
    end)
    return matching
end
local the_old_way = timed(50, buildTheOldWay)
report("the same, rebuilt from scratch every time", the_old_way,
    string.format("(%.1fx slower)", the_old_way / typing))
plugin.filter = nil
plugin:buildItemTable()

--== a recipe ==============================================================
print("\na recipe")
local raw = rawFull(1)
report("normalize the JSON Mealie sent", timed(200, function() Recipe.normalizeFull(raw) end))
local recipe = Recipe.normalizeFull(raw)
report("split it into chapters", timed(200, function() Recipe.toChapters(recipe) end))
report("store it (one file)", timed(50, function() plugin:cacheRecipe(recipe, true) end))
report("read it back when it is opened", timed(50, function() plugin:getCachedRecipe(recipe.slug) end))

--== what start-up has to parse ============================================
print("\nwhat KOReader parses at start-up")
local bodies = {}
for i = 1, RECIPES do
    local r = Recipe.normalizeFull(rawFull(i))
    bodies[r.slug] = r
end
local stamps = {}
for i = 1, RECIPES do stamps[list[i].slug] = list[i].updated_at end
local index_only = "return " .. dump({ list = list, stamps = stamps })
local with_bodies = "return " .. dump({ list = list, recipes = bodies })
print(string.format("  %-46s %5.0f kB", "cache file, recipes in it (the old shape)", #with_bodies / 1024))
print(string.format("  %-46s %5.0f kB   (%.1fx smaller)", "cache file, index and stamps only",
    #index_only / 1024, #with_bodies / #index_only))
report("parsing the old one", timed(5, function() assert(loadstring(with_bodies))() end))
report("parsing the new one", timed(5, function() assert(loadstring(index_only))() end))

plugin:forgetAllRecipes()
os.execute("rm -rf '" .. test_dir .. "'")
