local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/container/widgetcontainer")
local W = Widget:extend{ stub_name = "buttondialog" }

--- KOReader draws `checked_func` as a checkmark after the label and lets the
--- caller redraw it in place; these are the two methods that takes.
local function asButton(spec)
    spec.getDisplayText = function(this)
        return this.checked_func and this.checked_func() and (this.text .. "  \u{2713}") or this.text
    end
    spec.setText = function(this, text) this.text = text end
    return spec
end

function W:init()
    self.button_by_id = {}
    for i = 1, #(self.buttons or {}) do
        for j = 1, #self.buttons[i] do
            local spec = asButton(self.buttons[i][j])
            if spec.id then self.button_by_id[spec.id] = spec end
        end
    end
end
function W:getButtonById(id) return self.button_by_id and self.button_by_id[id] end
function W:getInputText() return self.input or "" end
function W:getFields() local out = {} for i = 1, #(self.fields or {}) do out[i] = self.fields[i].text end return out end
function W:onShowKeyboard() end
--- What Back and a tap outside do. A button that closes the dialog itself goes
--- straight to UIManager:close and never gets here -- as in KOReader.
function W:onClose()
    if self.tap_close_callback then self.tap_close_callback() end
    UIManager:close(self)
    return true
end
return W
