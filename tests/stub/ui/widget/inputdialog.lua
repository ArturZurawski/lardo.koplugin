local Widget = require("ui/widget/container/widgetcontainer")
local W = Widget:extend{ stub_name = "inputdialog" }
function W:getInputText() return self.input or "" end
function W:getFields() local out = {} for i = 1, #(self.fields or {}) do out[i] = self.fields[i].text end return out end
function W:onShowKeyboard() end
return W
