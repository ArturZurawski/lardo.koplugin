local Widget = require("ui/widget/widget")
local FrameContainer = Widget:extend{}
function FrameContainer:getSize()
    if self.width and self.height then return { w = self.width, h = self.height } end
    return self[1] and self[1]:getSize() or { w = 0, h = 0 }
end
return FrameContainer
