local Widget = require("ui/widget/widget")
local HorizontalGroup = Widget:extend{}
function HorizontalGroup:getSize()
    local w, h = 0, 0
    for i = 1, #self do
        local size = self[i]:getSize()
        w = w + (size.w or 0)
        h = math.max(h, size.h or 0)
    end
    return { w = w, h = h }
end
return HorizontalGroup
