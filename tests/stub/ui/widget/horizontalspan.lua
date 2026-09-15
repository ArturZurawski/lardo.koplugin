local Widget = require("ui/widget/widget")
local HorizontalSpan = Widget:extend{ width = 0 }
function HorizontalSpan:getSize() return { w = self.width, h = 0 } end
return HorizontalSpan
