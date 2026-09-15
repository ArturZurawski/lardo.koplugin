local Widget = require("ui/widget/widget")
local ButtonTable = Widget:extend{}
function ButtonTable:init()
    self.layout = {}
    for i = 1, #(self.buttons or {}) do
        self.layout[i] = self.buttons[i]
    end
end
function ButtonTable:getSize() return { w = self.width or 0, h = 50 } end
return ButtonTable
