-- Enough of KOReader's dump() for the recipe store: tables of strings,
-- numbers and booleans, serialized so that dofile() reads them back.
local function serialize(value, out, indent)
    local kind = type(value)
    if kind == "table" then
        out[#out + 1] = "{\n"
        for k, v in pairs(value) do
            out[#out + 1] = indent .. "    ["
            serialize(k, out, indent .. "    ")
            out[#out + 1] = "] = "
            serialize(v, out, indent .. "    ")
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    elseif kind == "string" then
        out[#out + 1] = string.format("%q", value)
    else
        out[#out + 1] = tostring(value)
    end
end

return function(value)
    local out = {}
    serialize(value, out, "")
    return table.concat(out)
end
