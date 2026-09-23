-- Run with: tests/run.sh  (needs any Lua 5.1 / LuaJIT interpreter)
local here = (arg[0] or "tests/x"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/stub/?.lua;" .. here .. "/../lardo.koplugin/?.lua;" .. package.path

local failures = 0
local checks = 0
local function check(cond, label, extra)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. label)
        if extra then print("      " .. tostring(extra)) end
    end
end
local function contains(haystack, needle, label)
    check(haystack:find(needle, 1, true) ~= nil, label, haystack)
end

--========================================================================
-- lardorecipe
--========================================================================
local Recipe = require("lardorecipe")

-- A realistic /api/recipes/{slug} payload (camelCase, as Mealie serializes it).
local raw = {
    id = "aaa-bbb",
    slug = "spaghetti-carbonara",
    name = "Spaghetti Carbonara",
    description = "Classic **Roman** pasta. See [the source](https://example.com/x).",
    totalTime = "30 Minutes",
    prepTime = "10 Minutes",
    performTime = "20 Minutes",
    recipeServings = 4,
    recipeYield = "4 servings",
    orgURL = "https://example.com/carbonara",
    recipeCategory = { { name = "Dinner" }, { name = "Pasta" } },
    tags = { { name = "italian" } },
    settings = { showNutrition = false },
    recipeIngredient = {
        { title = "Pasta", display = "400 g spaghetti", quantity = 400 },
        { display = "", quantity = 4, unit = { name = "piece", abbreviation = "pc", useAbbreviation = false },
          food = { name = "egg yolks" }, note = "room temperature" },
        { display = "", quantity = 2, unit = { name = "tablespoon", abbreviation = "tbsp", useAbbreviation = true },
          food = { name = "olive oil" } },
        { display = "", quantity = 0, note = "Black pepper, to taste" },
        { display = "", originalText = "Pecorino romano" },
    },
    recipeInstructions = {
        { title = "", text = "Boil the <b>pasta</b>.<br/>Salt the water well." },
        { title = "Sauce", text = "Whisk yolks with cheese &amp; pepper." },
        { title = "", text = "# Combine\nToss off the heat." },
    },
    notes = {
        { title = "Tip", text = "Never add cream." },
    },
}

local recipe = Recipe.normalizeFull(raw)
check(recipe ~= nil, "normalizeFull returns a recipe")
check(recipe.slug == "spaghetti-carbonara", "slug kept")
check(recipe.name == "Spaghetti Carbonara", "name kept")
check(recipe.description == "Classic Roman pasta. See the source.", "markdown stripped from description", recipe.description)
check(#recipe.ingredients == 5, "all ingredients kept", #recipe.ingredients)
check(recipe.ingredients[1].title == "Pasta", "ingredient section title kept")
check(recipe.ingredients[1].text == "400 g spaghetti", "display used verbatim", recipe.ingredients[1].text)
check(recipe.ingredients[2].text == "4 piece egg yolks (room temperature)",
    "ingredient built from parts", recipe.ingredients[2].text)
check(recipe.ingredients[3].text == "2 tbsp olive oil",
    "abbreviation used when useAbbreviation is set", recipe.ingredients[3].text)
check(recipe.ingredients[4].text == "Black pepper, to taste",
    "amount-less ingredient falls back to note", recipe.ingredients[4].text)
check(recipe.ingredients[5].text == "Pecorino romano",
    "falls back to originalText", recipe.ingredients[5].text)
check(#recipe.steps == 3, "all steps kept", #recipe.steps)
check(recipe.steps[1].text == "Boil the pasta.\nSalt the water well.",
    "html flattened in steps", recipe.steps[1].text)
check(recipe.steps[2].text == "Whisk yolks with cheese & pepper.",
    "entities decoded", recipe.steps[2].text)
check(recipe.steps[3].text == "Combine\nToss off the heat.",
    "markdown heading stripped", recipe.steps[3].text)
check(#recipe.notes == 1, "notes kept")
check(recipe.servings == "4", "servings normalized to string", recipe.servings)

-- Description, ingredients, instructions and notes are separate chapters
local chapters = Recipe.toChapters(recipe)
check(#chapters == 4, "four chapters for a full recipe", #chapters)
check(chapters[1].id == "description", "first chapter is the description", chapters[1].id)
check(chapters[2].id == "ingredients", "second chapter is the ingredients", chapters[2].id)
check(chapters[3].id == "instructions", "third chapter is the instructions", chapters[3].id)
check(chapters[4].id == "notes", "fourth chapter is the notes", chapters[4].id)
check(chapters[2].title == "Ingredients", "chapters carry a title", chapters[2].title)
contains(chapters[1].text, "Servings: 4", "servings in the description chapter")
contains(chapters[1].text, "Total: 30 Minutes", "total time in the description chapter")
contains(chapters[1].text, "Categories: Dinner, Pasta", "categories in the description chapter")
contains(chapters[1].text, "Classic Roman pasta", "the description prose itself")
contains(chapters[1].text, "Source: https://example.com/carbonara", "source in the description chapter")
contains(chapters[2].text, "- 400 g spaghetti", "ingredient bullet")
contains(chapters[3].text, "1. Boil the pasta.", "steps numbered")
contains(chapters[3].text, "3. Combine", "third step numbered")
contains(chapters[4].text, "Never add cream.", "note text")
check(chapters[2].text:find("Ingredients", 1, true) == nil,
    "the chapter title is not repeated inside the text", chapters[2].text)
check(Recipe.headerMeta(recipe) == "30 Minutes", "header shows the total time", Recipe.headerMeta(recipe))

-- Summary-only payloads (what /api/recipes returns)
local summary = Recipe.normalizeSummary({ slug = "soup", name = "Soup", totalTime = "45 min" })
check(summary.name == "Soup", "summary name")
check(Recipe.listMandatory(summary) == "45 min", "mandatory column uses total time")
check(Recipe.listMandatory(Recipe.normalizeSummary({ slug = "x", name = "X" })) == "",
    "mandatory column empty when no times")

-- the right-hand column: what the recipe is, then how long it takes
local tagged = Recipe.normalizeSummary({
    slug = "soup", name = "Soup", totalTime = "45 min",
    tags = { { name = "obiad" }, { name = "zupa" } },
})
check(Recipe.listTags(tagged) == "obiad, zupa", "the tags read as one phrase",
    Recipe.listTags(tagged))
check(Recipe.listColumn(tagged, true) == "obiad, zupa · 45 min",
    "and the time stays at the right edge, after them", Recipe.listColumn(tagged, true))
check(Recipe.listColumn(tagged, false) == "45 min",
    "with the tags switched off the column is the time alone", Recipe.listColumn(tagged, false))
check(Recipe.listColumn(summary, true) == "45 min",
    "an untagged recipe does not gain a separator with nothing before it",
    Recipe.listColumn(summary, true))
check(Recipe.listColumn(Recipe.normalizeSummary({
    slug = "t", name = "T", tags = { { name = "obiad" } } }), true) == "obiad",
    "nor a tagged one with no time in it")

-- the name has the first claim on a 600 px row, so the column gives way
local many_tags = Recipe.normalizeSummary({ slug = "m", name = "M", tags = {
    { name = "obiad" }, { name = "wegetariańskie" }, { name = "szybkie" } } })
check(Recipe.listTags(many_tags) == "obiad …",
    "tags that do not fit are counted, not crammed in", Recipe.listTags(many_tags))
local one_long = Recipe.normalizeSummary({ slug = "l", name = "L",
    tags = { { name = "dania jednogarnkowe z piekarnika" } } })
check(Recipe.listTags(one_long) == "dania jednogarnkowe z piekarnika",
    "the first tag is shown however long it is -- a row reading only \"…\" says nothing",
    Recipe.listTags(one_long))
check(Recipe.listTags({}) == "" and Recipe.listColumn({ total_time = "", perform_time = "",
    cook_time = "", prep_time = "" }, true) == "",
    "a list cached before tags were kept has none, and asks for nothing")

check(Recipe.normalizeSummary({ name = "no slug" }) == nil, "entries without slug/id are dropped")
check(Recipe.normalizeSummary({ id = "uuid-1", name = "By id" }).slug == "uuid-1", "falls back to id")
check(summary.updated_at == "", "no version stamp when the server sends none", summary.updated_at)
check(Recipe.normalizeSummary({ slug = "x", updatedAt = "2024-05-01T10:00:00" }).updated_at
    == "2024-05-01T10:00:00", "updatedAt is captured for change detection")
check(Recipe.normalizeSummary({ slug = "x", dateUpdated = "2024-05-02" }).updated_at == "2024-05-02",
    "dateUpdated is used when updatedAt is absent")

-- Empty recipe must still render something
local empty = Recipe.toChapters(Recipe.normalizeFull({ slug = "empty", name = "Empty" }))
check(#empty == 1 and empty[1].text == "This recipe has no content.",
    "empty recipe renders a placeholder chapter", empty[1] and empty[1].text)
check(Recipe.headerMeta(Recipe.normalizeFull({ slug = "e", name = "E" })) == "",
    "no header meta when there are no times")

--========================================================================
-- lardolang
--========================================================================
local Lang = require("lardolang")

check(Lang.baseCode("pl-PL") == "pl", "full tag reduced to the base code", Lang.baseCode("pl-PL"))
check(Lang.baseCode("PL") == "pl", "base code lower-cased")
check(Lang.baseCode(nil) == nil, "no code, no base")
check(Lang.isSupported("pl-PL"), "Polish is supported")
check(not Lang.isSupported("hu-HU"), "Hungarian has no wording yet")
check(Lang.nameFor("pt-BR") == "Português", "endonym for the menu", Lang.nameFor("pt-BR"))
check(Lang.nameFor("hu-HU") == "hu-HU", "unknown language shows its tag")

-- every language must carry every key, or a recipe would render half-translated
for code, strings in pairs(Lang.STRINGS) do
    for key in pairs(Lang.ENGLISH) do
        check(type(strings[key]) == "string" and strings[key] ~= "",
            "language " .. code .. " defines " .. key)
    end
end
for i = 1, #Lang.LANGUAGES do
    local entry = Lang.LANGUAGES[i]
    check(Lang.STRINGS[entry[1]] ~= nil, "menu language " .. entry[1] .. " has wording")
    check(Lang.baseCode(entry[2]) == entry[1], "menu tag matches its base code", entry[2])
end

Lang.set("pl-PL")
check(Lang.t("ingredients") == "Składniki", "wording follows the language", Lang.t("ingredients"))
local pl_chapters = Recipe.toChapters(recipe)
check(pl_chapters[2].title == "Składniki", "chapter titles follow the language", pl_chapters[2].title)
contains(pl_chapters[1].text, "Porcje: 4", "meta labels follow the language")
Lang.set("hu-HU")
check(Lang.t("ingredients") == "Ingredients", "unknown language falls back to English")
Lang.set(nil)
check(Lang.t("ingredients") == "Ingredients", "no language set falls back to English")

--========================================================================
-- lardoconfig
--========================================================================
local Config = require("lardoconfig")

local values = Config.parse([[
# comment line
; another comment
url = http://192.168.1.10:9000
TOKEN = "eyJhbGciOiJIUzI1NiJ9.abc-def_123"
username: me@example.com
password = s3cr3t
ignored_key = whatever
]])
check(values.url == "http://192.168.1.10:9000", "url parsed", values.url)
check(values.token == "eyJhbGciOiJIUzI1NiJ9.abc-def_123", "token parsed and unquoted", values.token)
check(values.username == "me@example.com", "username parsed with colon separator", values.username)
check(values.password == "s3cr3t", "password parsed", values.password)
check(values.ignored_key == nil, "unknown keys ignored")

local aliased = Config.parse("server=example.lan\r\napi_token=abc\r\n")
check(aliased.url == "example.lan", "server alias", aliased.url)
check(aliased.token == "abc", "api_token alias and CRLF handled", aliased.token)
check(next(Config.parse("token =\n")) == nil, "empty values are not imported")

--------------------------------------------------------------------------
-- where the file is looked for
--------------------------------------------------------------------------
local base = assert(os.getenv("MEALIE_TEST_DIR"), "run the suite through tests/run.sh")
local settings_conf = base .. "/koreader/settings/lardo.conf"
local data_conf     = base .. "/koreader/lardo.conf"
local home_conf     = base .. "/lardo.conf"

local function writeFile(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end
local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end
local function cleanConfs()
    os.remove(settings_conf)
    os.remove(data_conf)
    os.remove(home_conf)
end
cleanConfs()

Config.plugin_dir = nil
local paths = Config:getSearchPaths()
check(#paths == 3, "three locations without a plugin directory", #paths)
check(paths[1] == settings_conf, "koreader/settings is the default location", paths[1])
check(paths[2] == data_conf, "koreader/ is searched too", paths[2])
check(paths[3] == home_conf, "the device home directory is searched too", paths[3])
for i = 1, #paths do
    -- DataStorage:getDataDir() is "." on Kindle; a "./lardo.conf" shown in a
    -- dialog tells the user nothing about where to put the file.
    check(paths[i]:sub(1, 1) == "/", "search path " .. i .. " is absolute", paths[i])
end
check(Config:getPreferredPath() == settings_conf, "the default location is the preferred one")

Config.plugin_dir = base .. "/koreader/plugins/lardo.koplugin"
paths = Config:getSearchPaths()
check(#paths == 4, "the plugin directory adds a location", #paths)
check(paths[4] == Config.plugin_dir .. "/lardo.conf", "plugin directory searched last", paths[4])

-- PluginLoader hands out relative, doubly-slashed paths on Kindle
Config.plugin_dir = "./plugins//lardo.koplugin"
paths = Config:getSearchPaths()
check(paths[4] == base .. "/koreader/plugins/lardo.koplugin/lardo.conf",
    "a relative plugin path is resolved against the data directory", paths[4])

Config.plugin_dir = base -- same directory as Device.home_dir
check(#Config:getSearchPaths() == 3, "duplicate directories are collapsed", #Config:getSearchPaths())
Config.plugin_dir = nil

check(Config:describeSearchPaths() == table.concat(Config:getSearchPaths(), "\n"),
    "all locations are listed for the user")

-- each location is actually picked up, most specific first
check(Config:findFile() == nil, "no file anywhere means no path")
check(Config:read() == nil, "read() returns nil when there is no file")

writeFile(home_conf, "url = http://home\n")
check(Config:findFile() == home_conf, "file in the home directory is found", tostring(Config:findFile()))
local found_values, found_path = Config:read()
check(found_values.url == "http://home", "values read from the home directory", found_values.url)
check(found_path == home_conf, "read() reports the path it used")

writeFile(data_conf, "url = http://koreader\n")
check(Config:findFile() == data_conf, "koreader/ takes precedence over the home directory")
check(Config:read().url == "http://koreader", "values read from koreader/")

writeFile(settings_conf, "url = http://settings\n")
check(Config:findFile() == settings_conf, "koreader/settings takes precedence over everything")
check(Config:read().url == "http://settings", "values read from koreader/settings")

-- a filled-in file must never be overwritten by the template
local kept = Config:writeTemplate()
check(kept == settings_conf, "writeTemplate returns the existing file", tostring(kept))
check(readFile(settings_conf) == "url = http://settings\n", "existing file left untouched")

cleanConfs()
local written = Config:writeTemplate()
check(written == settings_conf, "template is created in the default location", tostring(written))
local template = Config:read()
check(template ~= nil and template.url == "http://192.168.1.10:9000",
    "the template parses back into an example url")
check(template == nil or template.token == nil, "the template leaves the token empty")
cleanConfs()

--------------------------------------------------------------------------
-- writing settings back into the file
--------------------------------------------------------------------------
writeFile(settings_conf, table.concat({
    "# my own notes",
    "url = http://old.lan",
    "token =",
    "username: me@example.com",
    "password = s3cr3t",
    "unknown_key = keep me",
    "",
}, "\n"))

local updated_path, updated_content = Config:update({ url = "http://new.lan:9000", token = "tok-new" })
check(updated_path == settings_conf, "update writes to the file that was found", tostring(updated_path))
check(updated_content:find("url = http://new.lan:9000", 1, true) ~= nil, "url replaced", updated_content)
check(updated_content:find("token = tok-new", 1, true) ~= nil, "empty token line filled in", updated_content)
check(updated_content:find("# my own notes", 1, true) ~= nil, "comments kept")
check(updated_content:find("username: me@example.com", 1, true) ~= nil, "colon style and username kept")
check(updated_content:find("password = s3cr3t", 1, true) ~= nil, "password kept")
check(updated_content:find("unknown_key = keep me", 1, true) ~= nil, "unknown keys kept")
check(updated_content:find("http://old.lan", 1, true) == nil, "the old value is gone")
check(readFile(settings_conf) == updated_content, "returned content is what landed on disk")

local round_trip = Config:read()
check(round_trip.url == "http://new.lan:9000" and round_trip.token == "tok-new",
    "the rewritten file parses back into the new values")
check(round_trip.password == "s3cr3t", "the rewritten file still carries the password")

-- a key the file does not mention at all gets appended
cleanConfs()
writeFile(settings_conf, "url = http://only-url.lan\n")
local _p, appended = Config:update({ token = "appended-token" })
check(appended:find("token = appended%-token") ~= nil, "missing key appended", appended)
check(Config:read().url == "http://only-url.lan", "the untouched key survives the append")

-- clearing a value
local _p2, cleared = Config:update({ token = "" })
check(cleared:find("token =\n") ~= nil, "an emptied value leaves the key in place", cleared)
check(Config:read().token == nil, "an emptied value is no longer imported")

-- no file at all: one is created from the template and then filled in
cleanConfs()
local fresh_path, fresh = Config:update({ url = "http://fresh.lan", token = "fresh-tok" })
check(fresh_path == settings_conf, "a missing file is created in the default location", tostring(fresh_path))
check(fresh:find("Lardo (Mealie recipes for KOReader) configuration", 1, true) ~= nil,
    "the created file keeps the explanatory header")
local fresh_values = Config:read()
check(fresh_values.url == "http://fresh.lan", "url written into the fresh file", fresh_values.url)
check(fresh_values.token == "fresh-tok", "token written into the fresh file", fresh_values.token)
cleanConfs()

--========================================================================
-- lardoapi
--========================================================================
-- Stub the socket stack so we can exercise the request builder end to end.
local last_request
local next_responses = {}
package.loaded["socket.http"] = {
    request = function(req)
        last_request = req
        local response = table.remove(next_responses, 1) or { code = 200, body = "{}" }
        if response.body then
            req.sink(response.body)
        end
        if response.transport_error then
            return nil, response.transport_error
        end
        return 1, response.code, {}, response.status or tostring(response.code)
    end,
}
package.loaded["socket"] = {
    skip = function(n, ...)
        local values_ = { ... }
        local out = {}
        for i = n + 1, #values_ do out[#out + 1] = values_[i] end
        return table.unpack and table.unpack(out) or unpack(out)
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
-- Very small JSON decoder, enough for the fixtures below.
package.loaded["json"] = { decode = function(str) return assert(load("return " .. str))() end }

local LardoApi = require("lardoapi")

check(LardoApi.new("192.168.1.10:9000"):getBaseUrl() == "http://192.168.1.10:9000",
    "scheme added when missing")
check(LardoApi.new("https://mealie.example.com/"):getBaseUrl() == "https://mealie.example.com",
    "trailing slash removed")
check(LardoApi.new("http://host/api"):getBaseUrl() == "http://host",
    "trailing /api removed")
check(LardoApi.new(""):getBaseUrl() == nil, "empty url is nil")
check(LardoApi.urlencode("a b/c?&=") == "a%20b%2Fc%3F%26%3D", "urlencode", LardoApi.urlencode("a b/c?&="))

local api = LardoApi.new("http://host:9000", "tok123")
next_responses = { { code = 200, body = '{items={{slug="a",name="A"}},total=1,total_pages=1,page=1}' } }
local items, err = api:getRecipeList()
check(items ~= nil, "getRecipeList succeeds", err)
check(#items == 1 and items[1].slug == "a", "recipe list decoded")
contains(last_request.url, "http://host:9000/api/recipes?", "recipes endpoint")
contains(last_request.url, "perPage=100", "perPage sent")
contains(last_request.url, "orderBy=name", "orderBy sent")
check(last_request.headers["Authorization"] == "Bearer tok123", "bearer token sent",
    tostring(last_request.headers["Authorization"]))

-- pagination is followed
next_responses = {
    { code = 200, body = '{items={{slug="a",name="A"}},total=2,total_pages=2,page=1}' },
    { code = 200, body = '{items={{slug="b",name="B"}},total=2,total_pages=2,page=2}' },
}
items = api:getRecipeList()
check(#items == 2, "second page fetched", #items)
contains(last_request.url, "page=2", "page parameter incremented")

-- error mapping
next_responses = { { code = 401, status = "401 Unauthorized" } }
local ok_, err401 = api:getRecipeList()
check(ok_ == nil, "401 is an error")
contains(err401, "rejected the credentials", "401 message")

next_responses = { { code = 500, status = "500 Internal Server Error" } }
local _x, err500 = api:getRecipeList()
contains(err500, "500", "5xx message mentions the status")

next_responses = { { transport_error = "connection refused" } }
local _y, errnet = api:getRecipeList()
contains(errnet, "connection refused", "transport error surfaced")

-- non-Mealie server answering with JSON that is not a recipe page
next_responses = { { code = 200, body = '{hello="world"}' } }
local _z, errshape = api:getRecipeList()
contains(errshape, "Unexpected answer", "unexpected shape reported")

-- login
next_responses = { { code = 200, body = '{access_token="abc.def",token_type="bearer"}' } }
local token = api:login("me", "pw")
check(token == "abc.def", "login returns the token", tostring(token))
check(last_request.method == "POST", "login is a POST")
contains(last_request.headers["Content-Type"], "x-www-form-urlencoded", "login content type")
check(last_request.headers["Authorization"] == nil, "login does not send a bearer token")
check(last_request.source == "username=me&password=pw&remember_me=true", "login body", last_request.source)

next_responses = { { code = 200, body = '{detail="nope"}' } }
local _t, errtok = api:login("me", "pw")
contains(errtok, "did not return an access token", "missing token reported")

-- single recipe
next_responses = { { code = 200, body = '{slug="x y",name="X"}' } }
api:getRecipe("x y")
contains(last_request.url, "/api/recipes/x%20y", "slug is url-encoded")

local _n, errnoslug = api:getRecipe("")
contains(errnoslug, "no identifier", "empty slug rejected")

local unset, errunset = LardoApi.new(nil, nil):getRecipeList()
check(unset == nil, "no url is an error")
contains(errunset, "not set", "no url message")

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
