local Widget = require("ui/widget/widget")
-- A line-based stand-in: enough to exercise paging, scrolling and ratios.
local LINE_HEIGHT = 20
local TextBoxWidget = Widget:extend{}
function TextBoxWidget:init()
    self.lines = {}
    for line in ((self.text or "") .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(self.lines, line)
    end
    if #self.lines == 0 then self.lines = { "" } end
    self.lines_per_page = math.max(1, math.floor((self.height or LINE_HEIGHT) / LINE_HEIGHT))
    self.virtual_line_num = 1
    self.freed = false
end
function TextBoxWidget:getSize()
    return { w = self.width or 0, h = math.min(#self.lines, self.lines_per_page) * LINE_HEIGHT }
end
function TextBoxWidget:scrollDown()
    if self.virtual_line_num + self.lines_per_page <= #self.lines then
        self.virtual_line_num = self.virtual_line_num + self.lines_per_page
    end
end
function TextBoxWidget:scrollUp()
    if self.virtual_line_num > 1 then
        self.virtual_line_num = math.max(1, self.virtual_line_num - self.lines_per_page)
    end
end
function TextBoxWidget:scrollLines(nb)
    local target = self.virtual_line_num + nb
    local max = math.max(1, #self.lines - self.lines_per_page + 1)
    if target < 1 then target = 1 elseif target > max then target = max end
    self.virtual_line_num = target
end
function TextBoxWidget:scrollToBottom()
    self.virtual_line_num = math.max(1, #self.lines - self.lines_per_page + 1)
end
function TextBoxWidget:scrollToTop() self.virtual_line_num = 1 end
function TextBoxWidget:getVisibleHeightRatios()
    local low = (self.virtual_line_num - 1) / #self.lines
    local high = (self.virtual_line_num - 1 + self.lines_per_page) / #self.lines
    return low, high
end
function TextBoxWidget:free() self.freed = true end
return TextBoxWidget
