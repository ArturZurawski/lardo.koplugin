local WidgetContainer = require("ui/widget/container/widgetcontainer")
-- A container that can take gestures: KOReader matches a tap against the ranges
-- in `ges_events` and calls the handler named by the key. Children are asked
-- first (WidgetContainer:propagateEvent), which is how a tap on the field
-- itself never reaches the catcher underneath it.
local InputContainer = WidgetContainer:extend{}
function InputContainer:getSize()
    return self.dimen or (self[1] and self[1]:getSize()) or { w = 0, h = 0 }
end
return InputContainer
