local Widget = require("ui/widget/widget")
local VerticalGroup = Widget:extend{}
function VerticalGroup:getSize()
    local w, h = 0, 0
    for i = 1, #self do
        local size = self[i]:getSize()
        w = math.max(w, size.w or 0)
        h = h + (size.h or 0)
    end
    return { w = w, h = h }
end
return VerticalGroup
