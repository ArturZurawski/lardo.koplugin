local Widget = require("ui/widget/container/widgetcontainer")
-- KOReader's folder picker: the test confirms a path the way a finger would.
-- It calls onConfirm(path) as a plain function, not as a method -- so does this.
local PathChooser = Widget:extend{ stub_name = "pathchooser" }
function PathChooser:confirm(path)
    if self.onConfirm then self.onConfirm(path) end
end
return PathChooser
