local Widget = require("ui/widget/container/widgetcontainer")
-- KOReader's SortWidget: a list whose items can be moved and ticked. The test
-- moves them by hand and calls the callback, which is what the real one does
-- when the ✓ in its footer is pressed.
local SortWidget = Widget:extend{ stub_name = "sortwidget" }
function SortWidget:moveItem(from, to)
    local item = table.remove(self.item_table, from)
    table.insert(self.item_table, to, item)
end
function SortWidget:accept() if self.callback then self:callback() end end
return SortWidget
