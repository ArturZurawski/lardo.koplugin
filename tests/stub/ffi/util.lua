local util = {}
function util.template(str, ...)
    local args = {...}
    return (str:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
return util
