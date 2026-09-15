local lfs = {}

-- Directories we were asked to create. A plain io.open() cannot tell a
-- directory from a file portably, and the only directory the plugin ever asks
-- about is the one it makes itself.
local made = {}

function lfs.attributes(path, what)
    if made[path] then
        if what == "mode" then return "directory" end
        return { mode = "directory" }
    end
    local f = io.open(path, "r")
    if f then
        f:close()
        if what == "mode" then return "file" end
        return { mode = "file" }
    end
    return nil
end

function lfs.mkdir(path)
    os.execute("mkdir -p '" .. path .. "'")
    made[path] = true
    return true
end

return lfs
