--[[--
Minimal HTTP client for the Mealie API (v1).

Only the read-only endpoints we need are implemented:
  POST /api/auth/token   -- exchange username/password for a bearer token
  GET  /api/recipes      -- paginated recipe summaries
  GET  /api/recipes/{slug}
  GET  /api/users/self   -- who we are, for the line below
  GET  /api/users/{id}/favorites

@module koplugin.lardo.api
--]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local T = require("ffi/util").template
local _ = require("lardoi18n").gettext

local LardoApi = {}
LardoApi.__index = LardoApi

-- Mealie caps perPage on some deployments; 100 is a safe compromise between
-- round-trips and the amount of JSON an old Kindle has to parse in one go.
local PAGE_SIZE = 100
local MAX_PAGES = 100

-- Mealie localizes every response from the request's Accept-Language header
-- (mealie/middleware/locale_context.py); it has no stored "language" setting
-- we could read back, so we tell it which one we want on every call.
function LardoApi.new(url, token, language)
    return setmetatable({ url = url, token = token, language = language }, LardoApi)
end

local function urlencode(str)
    return (tostring(str):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end
LardoApi.urlencode = urlencode

--- Normalizes whatever the user typed into a scheme-qualified base URL.
-- Accepts "192.168.1.10:9000", "http://host/", "https://host/api" ...
function LardoApi:getBaseUrl()
    local url = (self.url or ""):gsub("%s", "")
    if url == "" then return nil end
    if not url:match("^https?://") then
        url = "http://" .. url
    end
    url = url:gsub("/+$", "")
    url = url:gsub("/api$", "") -- we add /api ourselves
    return url
end

function LardoApi:hasToken()
    return self.token ~= nil and self.token ~= ""
end

--- Performs a request and decodes the JSON body.
-- @return table decoded body, or nil plus a human readable error message
function LardoApi:request(method, path, opts)
    opts = opts or {}
    local base = self:getBaseUrl()
    if not base then
        return nil, _("Mealie server address is not set.")
    end

    local url = base .. path
    if opts.query then
        local parts = {}
        for i = 1, #opts.query do
            local kv = opts.query[i]
            if kv[2] ~= nil then
                table.insert(parts, urlencode(kv[1]) .. "=" .. urlencode(kv[2]))
            end
        end
        if #parts > 0 then
            url = url .. "?" .. table.concat(parts, "&")
        end
    end

    local headers = { ["Accept"] = "application/json" }
    if self.language and self.language ~= "" then
        headers["Accept-Language"] = self.language
    end
    if opts.with_token ~= false and self:hasToken() then
        headers["Authorization"] = "Bearer " .. self.token
    end
    local source
    if opts.body then
        headers["Content-Type"] = opts.content_type or "application/json"
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end

    local sink = {}
    socketutil:set_timeout(opts.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
                           opts.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    logger.dbg("Lardo: request", method or "GET", url)
    local code, _resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = method or "GET",
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if type(code) ~= "number" then
        -- LuaSocket puts the failure reason in the first return value here.
        logger.warn("Lardo: network error", code, status)
        return nil, T(_("Could not reach the Mealie server.\n%1"), tostring(code or status or "?"))
    end

    if code == 401 or code == 403 then
        return nil, _("Mealie rejected the credentials. Check the token, or log in again.")
    elseif code == 404 then
        return nil, _("Not found on the Mealie server. Check the server address.")
    elseif code < 200 or code > 299 then
        return nil, T(_("Mealie server returned an error: %1"), tostring(status or code))
    end

    local content = table.concat(sink)
    if content == "" then
        return nil, _("Mealie server returned an empty response.")
    end
    local ok, result = pcall(JSON.decode, content)
    if not ok or type(result) ~= "table" then
        logger.warn("Lardo: invalid JSON", content:sub(1, 200))
        return nil, _("Mealie server returned a response that is not valid JSON.\nIs the server address correct?")
    end
    return result
end

--- Exchanges username/password for a long-ish lived bearer token.
function LardoApi:login(username, password)
    local body = "username=" .. urlencode(username)
        .. "&password=" .. urlencode(password)
        .. "&remember_me=true"
    local data, err = self:request("POST", "/api/auth/token", {
        body = body,
        content_type = "application/x-www-form-urlencoded",
        with_token = false,
    })
    if not data then return nil, err end
    if type(data.access_token) ~= "string" or data.access_token == "" then
        return nil, _("Mealie did not return an access token.")
    end
    return data.access_token
end

--- Fetches every recipe summary, following the pagination.
-- @param progress_cb optional function(fetched_count, total_count)
function LardoApi:getRecipeList(progress_cb)
    local items = {}
    local page = 1
    local total_pages = 1
    repeat
        local data, err = self:request("GET", "/api/recipes", {
            query = {
                { "page", page },
                { "perPage", PAGE_SIZE },
                { "orderBy", "name" },
                { "orderDirection", "asc" },
            },
        })
        if not data then return nil, err end
        if type(data.items) ~= "table" then
            return nil, _("Unexpected answer from the Mealie server.\nIs this really a Mealie instance?")
        end
        for i = 1, #data.items do
            table.insert(items, data.items[i])
        end
        total_pages = tonumber(data.total_pages) or tonumber(data.totalPages) or 1
        if progress_cb then
            progress_cb(#items, tonumber(data.total) or #items)
        end
        page = page + 1
    until page > total_pages or page > MAX_PAGES
    return items
end

--- Fetches a single recipe (accepts a slug or an id).
function LardoApi:getRecipe(slug)
    if slug == nil or slug == "" then
        return nil, _("This recipe has no identifier.")
    end
    return self:request("GET", "/api/recipes/" .. urlencode(slug))
end

local function idString(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The recipe ids the user has marked as favourites in Mealie.
--
-- Favourites are per user, so this takes two requests: who we are, and what we
-- starred (`/api/users/{id}/favorites` answers `{ratings = {{recipeId = …}}}`).
-- Every failure is a soft one -- an older Mealie without the endpoint simply
-- means no favourites, never a broken recipe list.
-- @return set of recipe ids, or nil
function LardoApi:getFavoriteIds()
    local me = self:request("GET", "/api/users/self")
    local id = type(me) == "table" and idString(me.id) or ""
    if id == "" then return nil end

    local data = self:request("GET", "/api/users/" .. urlencode(id) .. "/favorites")
    local ratings = type(data) == "table" and data.ratings
    if type(ratings) ~= "table" then return nil end

    local favorites = {}
    for i = 1, #ratings do
        local entry = ratings[i]
        local recipe_id = type(entry) == "table" and idString(entry.recipeId or entry.recipe_id) or ""
        if recipe_id ~= "" then
            favorites[recipe_id] = true
        end
    end
    return favorites
end

--- Cheap round-trip used by "Test connection".
function LardoApi:testConnection()
    local data, err = self:request("GET", "/api/recipes", {
        query = { { "page", 1 }, { "perPage", 1 } },
        block_timeout = 10,
        total_timeout = 20,
    })
    if not data then return nil, err end
    if type(data.items) ~= "table" then
        return nil, _("Unexpected answer from the Mealie server.\nIs this really a Mealie instance?")
    end
    return tonumber(data.total) or #data.items
end

return LardoApi
