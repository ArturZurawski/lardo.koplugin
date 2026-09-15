local GestureRange = {}
GestureRange.__index = GestureRange
function GestureRange:new(spec) return setmetatable(spec or {}, GestureRange) end
return GestureRange
