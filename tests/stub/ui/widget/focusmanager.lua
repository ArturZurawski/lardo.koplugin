local Widget = require("ui/widget/widget")
-- Mirrors the real FocusManager closely enough for key registration tests:
-- _init seeds the D-pad bindings, releaseFocusKeys drops them.
local DEFAULTS = {
    FocusUp = true, FocusDown = true, FocusLeft = true, FocusRight = true,
    Press = true, Home = true, FocusNext = true, FocusPrevious = true,
    HalfFocusUp = true, HalfFocusDown = true, HalfFocusLeft = true, HalfFocusRight = true,
}
local FocusManager = Widget:extend{}
function FocusManager:_init()
    self.key_events = {}
    for name in pairs(DEFAULTS) do
        self.key_events[name] = { { name } }
    end
    self.released_focus_keys = {}
    self.selected = { x = 1, y = 1 }
end
function FocusManager:releaseFocusKeys(...)
    for _, name in ipairs({ ... }) do
        self.released_focus_keys[name] = true
        self.key_events[name] = nil
    end
end
return FocusManager
