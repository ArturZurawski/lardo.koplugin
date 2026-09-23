local Widget = require("ui/widget/widget")
-- Enough of InputText for the filter field: it holds text, tells its owner on
-- every change -- which is what makes the filtering live rather than something
-- that happens once at the end -- and owns the keyboard that is typed on.
local InputText = Widget:extend{ stub_name = "inputtext" }

function InputText:init()
    self.text = self.text or ""
    self.keyboard_shown = false
    -- The real one fires this from its constructor, with false: "called with
    -- true when text modified, false on init or text re-set". So a callback
    -- that reaches for something its caller has not finished building yet
    -- fails before the widget even exists, which is a thing that happened.
    if self.edit_callback then self.edit_callback(false) end
end

function InputText:getText() return self.text end

--- One keystroke, as the virtual keyboard delivers it. Enter is not text: the
-- real one schedules `enter_callback` for it instead of adding a line.
function InputText:addChars(chars)
    if chars == "\n" then
        if self.enter_callback then self.enter_callback() end
        return
    end
    self.text = self.text .. chars
    if self.edit_callback then self.edit_callback(true) end
end

--- The backspace key. The real one deletes the character before the cursor and
-- tells its owner; with nothing to delete it does nothing at all, which is what
-- makes "backspace out of an empty field" something a caller can act on.
function InputText:delChar()
    if self.text == "" then return end
    self.text = self.text:sub(1, -2)
    if self.edit_callback then self.edit_callback(true) end
end

--- The keyboard is a widget of its own, shown over the bottom of the screen;
-- what matters here is where it is, because a tap that lands on it is not a tap
-- outside the field.
function InputText:onShowKeyboard()
    self.keyboard_shown = true
    self.keyboard = self.keyboard
        or { dimen = { x = 0, y = 500, w = 600, h = 300 } }
    return true
end
function InputText:onCloseKeyboard() self.keyboard_shown = false end

return InputText
