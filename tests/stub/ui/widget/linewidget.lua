local Widget = require("ui/widget/widget")
local LineWidget = Widget:extend{}
function LineWidget:getSize() return self.dimen or { w = 0, h = 1 } end
return LineWidget
