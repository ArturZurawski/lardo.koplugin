local Widget = require("ui/widget/widget")
local TextWidget = Widget:extend{}
function TextWidget:getSize()
    local w = #(self.text or "") * 8
    if self.max_width and w > self.max_width then w = self.max_width end
    return { w = w, h = 22 }
end
return TextWidget
