--[[--
Plain text configuration file support.

Mealie API tokens are long JWTs; typing one on a Kindle keyboard is not
realistic, so the server address and token can also be dropped into a small
text file over USB. The file is picked up automatically and re-imported
whenever its contents change.

Looked for in this order (on a Kindle):
    /mnt/us/koreader/settings/lardo.conf   <- default, next to our other settings
    /mnt/us/koreader/lardo.conf
    /mnt/us/lardo.conf
    /mnt/us/koreader/plugins/lardo.koplugin/lardo.conf

Recognized keys (`key = value`, `#` starts a comment):
    url       = http://192.168.1.10:9000
    token     = eyJhbGciOi...
    username  = me@example.com     (optional, used only if no token is given)
    password  = secret             (optional)
    language  = pl-PL              (optional, sent to Mealie as Accept-Language)

@module koplugin.lardo.config
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Config = {}

local FILENAME = "lardo.conf"

local ALIASES = {
    url = "url", server = "url", server_url = "url", host = "url", address = "url",
    token = "token", api_token = "token", api_key = "token", access_token = "token",
    username = "username", user = "username", login = "username", email = "username",
    password = "password", pass = "password",
    language = "language", lang = "language", locale = "language",
}

--- Set by the plugin so we can also look next to main.lua.
Config.plugin_dir = nil

--- Every place we look for the file, the default one first.
-- Paths must be absolute: they are shown to the user, who has to find them
-- over USB. DataStorage:getDataDir() is a bare "." on Kindle (koreader.sh only
-- chdirs into the install directory), hence getFullDataDir().
function Config:getSearchPaths(filename)
    local data_dir = DataStorage:getFullDataDir()
    local paths, seen = {}, {}
    local function add(dir)
        if not dir or dir == "" then return end
        if dir:sub(1, 1) ~= "/" then
            -- PluginLoader hands out paths like "./plugins//lardo.koplugin";
            -- KOReader runs with the data directory as its working directory.
            dir = (data_dir or ".") .. "/" .. dir:gsub("^%./", "")
        end
        dir = dir:gsub("//+", "/"):gsub("(.)/$", "%1")
        if not seen[dir] then
            seen[dir] = true
            table.insert(paths, dir .. "/" .. (filename or FILENAME))
        end
    end

    add(data_dir and data_dir .. "/settings")
    add(data_dir)
    add(Device.home_dir)
    add(self.plugin_dir)
    return paths
end

--- Path we suggest to the user (and write the template to).
function Config:getPreferredPath()
    return self:getSearchPaths()[1]
end

--- All the places we look, one per line, for the "where do I put this?" dialogs.
function Config:describeSearchPaths()
    return table.concat(self:getSearchPaths(), "\n")
end

function Config:findFile()
    local paths = self:getSearchPaths()
    for i = 1, #paths do
        if lfs.attributes(paths[i], "mode") == "file" then
            return paths[i]
        end
    end
    return nil
end

local function parse(content)
    local values = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r", "")
        if not line:match("^%s*[#;]") then
            local key, value = line:match("^%s*([%w_%-]+)%s*[=:]%s*(.-)%s*$")
            if key then
                local field = ALIASES[key:lower()]
                if field then
                    -- allow quoting, tokens themselves never contain quotes
                    value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
                    if value ~= "" then
                        values[field] = value
                    end
                end
            end
        end
    end
    return values
end
Config.parse = parse

--- Reads the config file, if there is one.
-- @return table of values, path, raw content -- or nil if no file was found
function Config:read()
    local path = self:findFile()
    if not path then return nil end
    local file = io.open(path, "r")
    if not file then
        logger.warn("Lardo: cannot open", path)
        return nil
    end
    local content = file:read("*a") or ""
    file:close()
    return parse(content), path, content
end

--- Writes a commented template the user can fill in over USB.
-- @return path, or nil plus an error message
function Config:writeTemplate()
    local path = self:findFile() or self:getPreferredPath()
    if lfs.attributes(path, "mode") == "file" then
        return path -- never clobber a file the user already filled in
    end
    local file, err = io.open(path, "w")
    if not file then
        return nil, err or path
    end
    file:write(table.concat({
        "# Lardo (Mealie recipes for KOReader) configuration",
        "# Edit this file over USB, then choose",
        "# \"Reload configuration file\" in the Lardo menu (or just restart KOReader).",
        "",
        "url = http://192.168.1.10:9000",
        "token =",
        "",
        "# Instead of a token you can put your Mealie login here and use",
        "# \"Log in with username and password\" once; the token is then stored",
        "# by the plugin and you can remove these two lines again.",
        "#username =",
        "#password =",
        "",
        "# Language Mealie should answer in, and the wording of the recipe",
        "# chapters. Leave empty to follow KOReader's own language.",
        "#language = pl-PL",
        "",
    }, "\n"))
    file:close()
    return path
end

--- Order used when a key has to be appended because the file lacks it.
local FIELD_ORDER = { "url", "token", "username", "password", "language" }

local function assignment(indent, key, separator, value)
    if value == "" then
        return indent .. key .. " " .. separator
    end
    return indent .. key .. " " .. separator .. " " .. value
end

--- Writes values back into the config file, keeping comments, order and any keys
-- we do not know about. Creates the file from the template if there is none,
-- so what the user sees over USB always matches what the plugin is using.
-- @param updates table of field name -> new value; "" clears the value
-- @return path, new file content -- or nil plus an error message
function Config:update(updates)
    if not self:findFile() then
        local created, create_err = self:writeTemplate()
        if not created then
            return nil, create_err
        end
    end
    local path = self:findFile()
    if not path then
        return nil, self:getPreferredPath()
    end

    local existing = ""
    local file = io.open(path, "r")
    if file then
        existing = file:read("*a") or ""
        file:close()
    end

    local pending = {}
    for field, value in pairs(updates) do
        pending[field] = tostring(value or "")
    end

    local out = {}
    local body = existing:gsub("\r\n", "\n"):gsub("\n$", "")
    if body ~= "" then
        for line in (body .. "\n"):gmatch("([^\n]*)\n") do
            local replaced = false
            if not line:match("^%s*[#;]") then
                local indent, key, separator = line:match("^(%s*)([%w_%-]+)%s*([=:])")
                local field = key and ALIASES[key:lower()]
                if field and pending[field] then
                    table.insert(out, assignment(indent, key, separator, pending[field]))
                    pending[field] = nil
                    replaced = true
                end
            end
            if not replaced then
                table.insert(out, line)
            end
        end
    end

    for i = 1, #FIELD_ORDER do
        local field = FIELD_ORDER[i]
        if pending[field] then
            table.insert(out, assignment("", field, "=", pending[field]))
        end
    end

    local content = table.concat(out, "\n") .. "\n"
    local handle, err = io.open(path, "w")
    if not handle then
        return nil, err or path
    end
    handle:write(content)
    handle:close()
    return path, content
end

return Config
