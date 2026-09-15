--[[--
Full screen recipe reader.

Deliberately not a TextViewer: on a 600x800 screen the framed, inset dialog
with its big title bar and button row costs roughly a quarter of the page. This
widget paints edge to edge and spends its chrome on one compact header line
(recipe name + time) plus, when a recipe has several chapters, a second line
with the chapter name and position. The button row follows the device (shown on a
touch screen, hidden where there are keys for the same things), and the reading
position is a hairline bar rather than a row of text.

Description, ingredients, instructions and notes are separate chapters, so you
can jump to the one you need instead of scrolling past the other three.

@module koplugin.lardo.view
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen
local _ = require("lardoi18n").gettext

--- A hairline reading-position bar.
-- With `segments` it draws one span per chapter, each filling on its own, and
-- each aligned with that chapter's name in the header above. Without them it
-- is a plain bar, used for the single-chapter and vertical cases.
local ProgressLine = Widget:extend{
    width = 0,
    height = 0,
    percentage = 0,
    vertical = false,
    segments = nil, -- { { x = , w = , ratio = }, ... }
}

function ProgressLine:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

local function clampRatio(ratio)
    if not ratio or ratio < 0 then return 0 end
    if ratio > 1 then return 1 end
    return ratio
end

function ProgressLine:paintTo(bb, x, y)
    if self.segments then
        for i = 1, #self.segments do
            local segment = self.segments[i]
            bb:paintRect(x + segment.x, y, segment.w, self.height, Blitbuffer.COLOR_LIGHT_GRAY)
            local filled = math.floor(segment.w * clampRatio(segment.ratio))
            if filled > 0 then
                bb:paintRect(x + segment.x, y, filled, self.height, Blitbuffer.COLOR_BLACK)
            end
        end
        return
    end

    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_LIGHT_GRAY)
    local ratio = clampRatio(self.percentage)
    if self.vertical then
        local filled = math.floor(self.height * ratio)
        if filled > 0 then
            bb:paintRect(x, y, self.width, filled, Blitbuffer.COLOR_BLACK)
        end
    else
        local filled = math.floor(self.width * ratio)
        if filled > 0 then
            bb:paintRect(x, y, filled, self.height, Blitbuffer.COLOR_BLACK)
        end
    end
end

local LardoView = FocusManager:extend{
    title = "",
    meta = "",            -- right hand side of the header, e.g. "45 min"
    chapters = nil,       -- { { id = , title = , text = }, ... }
    chapter_index = 1,
    font_size = 20,
    font_face = nil,      -- font file path from FontChooser; nil = KOReader's UI font
    progress_position = "top", -- "top" | "bottom" | "side" | "off"
    show_buttons = false,
    -- callbacks
    close_callback = nil,
    next_recipe_callback = nil,
    prev_recipe_callback = nil,
    menu_callback = nil,

    covers_fullscreen = true,
}

--- Header stays in the UI font: it must never break because the chosen
-- reading font lacks a glyph, and its height has to stay predictable.
local HEADER_TITLE_SIZE = 17
local HEADER_LINE_SIZE = 15

function LardoView:init()
    if not self.chapters or #self.chapters == 0 then
        self.chapters = { { id = "empty", title = "", text = "" } }
    end
    if self.chapter_index < 1 or self.chapter_index > #self.chapters then
        self.chapter_index = 1
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    -- how much of each chapter has been seen; survives chapter switches
    self.chapter_progress = self.chapter_progress or {}
    self:registerKeyEvents()
    self:registerTouchEvents()
    self:buildLayout()
end

--==========================================================================
-- Keys
--==========================================================================

--- FocusManager:releaseFocusKeys() is a recent addition; on an older KOReader
-- we still have to take the keys, we just cannot survive a keyboard hot-plug.
function LardoView:dropFocusKeys(...)
    if self.releaseFocusKeys then
        return self:releaseFocusKeys(...)
    end
    for _i = 1, select("#", ...) do
        self.key_events[select(_i, ...)] = nil
    end
end

function LardoView:registerKeyEvents()
    if not Device:hasKeys() then return end

    -- Up/Down scroll the text instead of moving focus. With no buttons on
    -- screen there is nothing to focus at all, so we claim the rest too.
    self:dropFocusKeys("FocusUp", "FocusDown", "HalfFocusUp", "HalfFocusDown", "Home")
    if not self.show_buttons then
        self:dropFocusKeys("FocusLeft", "FocusRight", "HalfFocusLeft", "HalfFocusRight",
            "Press", "FocusNext", "FocusPrevious")
    end

    self.key_events.Close = { { Device.input.group.Back } }
    self.key_events.LardoShowMenu = { { "Menu" } }
    self.key_events.LardoPageDown = { { Device.input.group.PgFwd }, event = "LardoScrollPage", args = 1 }
    self.key_events.LardoPageUp = { { Device.input.group.PgBack }, event = "LardoScrollPage", args = -1 }
    self.key_events.LardoLineDown = { { "Down" }, event = "LardoScrollLine", args = 1 }
    self.key_events.LardoLineUp = { { "Up" }, event = "LardoScrollLine", args = -1 }

    if #self.chapters > 1 and not self.show_buttons then
        -- with buttons on screen Left/Right belong to the button row
        self.key_events.LardoChapterNext = { { "Right" }, event = "LardoChapter", args = "next" }
        self.key_events.LardoChapterPrev = { { "Left" }, event = "LardoChapter", args = "previous" }
    end
    for i = 1, math.min(9, #self.chapters) do
        self.key_events["LardoChapter" .. i] = { { tostring(i) }, event = "LardoChapter", args = i }
    end
    -- "S" toggles the ingredients: the chapter you keep glancing at mid-cooking
    if self:findChapter("ingredients") then
        self.key_events.LardoIngredients = { { "S" } }
    end

    if Device:hasKeyboard() or Device:hasScreenKB() then
        local modifier = Device:hasScreenKB() and "ScreenKB" or "Shift"
        self.key_events.LardoNextRecipe = { { modifier, Device.input.group.PgFwd } }
        self.key_events.LardoPrevRecipe = { { modifier, Device.input.group.PgBack } }
    end
end

--==========================================================================
-- Touch
--==========================================================================

--- The same reading model as the keys, with a finger: the page turns where a
-- book's page turns, the chapters are where they are drawn, and the header is
-- the one piece of chrome you can hit to get out or to the menu.
--
-- The header strip is split at the meta text on the right (the total time),
-- because that corner is the only part of the header that is never a chapter
-- name: tapping it opens the menu, the rest of the strip leaves the recipe.
function LardoView:registerTouchEvents()
    if not Device:isTouchDevice() then return end
    local screen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = self.ges_events or {}
    self.ges_events.LardoTap = { GestureRange:new{ ges = "tap", range = screen } }
    self.ges_events.LardoSwipe = { GestureRange:new{ ges = "swipe", range = screen } }
    -- a long press anywhere is the menu, so it is reachable even mid-chapter
    self.ges_events.LardoHold = { GestureRange:new{ ges = "hold", range = screen } }
end

--- @return "header", "back" (the left third of the body) or "forward"
function LardoView:tapZone(pos)
    if not pos then return "forward" end
    if self.header_height and pos.y <= self.header_height then
        return "header"
    end
    return pos.x < Screen:getWidth() / 3 and "back" or "forward"
end

function LardoView:onLardoTap(_arg, ges)
    local zone = self:tapZone(ges and ges.pos)
    if zone == "header" then
        -- right hand end of the header: the menu; the rest: back to the list
        if ges and ges.pos and ges.pos.x > Screen:getWidth() * 2 / 3 then
            return self:onLardoShowMenu()
        end
        return self:onClose()
    end
    return self:onLardoScrollPage(zone == "back" and -1 or 1)
end

function LardoView:onLardoSwipe(_arg, ges)
    local direction = ges and ges.direction
    if direction == "west" then
        return self:onLardoChapter("next")
    elseif direction == "east" then
        return self:onLardoChapter("previous")
    elseif direction == "north" then
        return self:onLardoScrollPage(1)
    elseif direction == "south" then
        return self:onLardoScrollPage(-1)
    end
    return true
end

function LardoView:onLardoHold()
    return self:onLardoShowMenu()
end

--==========================================================================
-- Layout
--==========================================================================

function LardoView:getBodyFace()
    if self.font_face and self.font_face ~= "" then
        local face = Font:getFace(self.font_face, self.font_size)
        if face then return face end
    end
    return Font:getFace("cfont", self.font_size)
end

--- One header line: text on the left, a short value on the right.
local function headerRow(screen_w, h_padding, left_text, right_text, left_face, right_face, bold)
    local right_widget, right_w
    if right_text and right_text ~= "" then
        right_widget = TextWidget:new{ text = right_text, face = right_face }
        right_w = right_widget:getSize().w
    else
        right_w = 0
    end
    local left_max = screen_w - 2 * h_padding - (right_w > 0 and right_w + h_padding or 0)
    if left_max < 0 then left_max = 0 end
    local left_widget = TextWidget:new{
        text = left_text or "",
        face = left_face,
        bold = bold,
        max_width = left_max,
    }
    local gap = screen_w - 2 * h_padding - left_widget:getSize().w - right_w
    if gap < 0 then gap = 0 end

    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = h_padding },
        left_widget,
        HorizontalSpan:new{ width = gap },
    }
    if right_widget then
        table.insert(row, right_widget)
    end
    table.insert(row, HorizontalSpan:new{ width = h_padding })
    return row
end

--- Font sizes tried for the chapter row, largest first.
local CHAPTER_ROW_SIZES = { 15, 13, 11 }

--- The row of chapter names. All chapters are always listed; the one being
-- read is bold and black, the others dark grey.
-- @return the widget, the x/width span of each name, its total width
function LardoView:buildChapterRow(screen_w, h_padding, face, max_width)
    local gap = h_padding
    local row = HorizontalGroup:new{ align = "center" }
    local spans = {}
    local x = h_padding

    table.insert(row, HorizontalSpan:new{ width = h_padding })
    for i = 1, #self.chapters do
        local is_current = i == self.chapter_index
        local name = TextWidget:new{
            text = self.chapters[i].title,
            face = face,
            bold = is_current,
            fgcolor = is_current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            max_width = max_width,
        }
        local width = name:getSize().w
        table.insert(row, name)
        spans[i] = { x = x, w = width, ratio = 0 }
        x = x + width
        if i < #self.chapters then
            table.insert(row, HorizontalSpan:new{ width = gap })
            x = x + gap
        end
    end
    return row, spans, x - h_padding
end

--- Shrinks the font until the chapter names fit, then truncates as a last resort.
function LardoView:buildFittedChapterRow(screen_w, h_padding)
    local available = screen_w - 2 * h_padding
    local row, spans, width, face
    for i = 1, #CHAPTER_ROW_SIZES do
        face = Font:getFace("cfont", CHAPTER_ROW_SIZES[i])
        row, spans, width = self:buildChapterRow(screen_w, h_padding, face)
        if width <= available then
            return row, spans
        end
    end
    -- still too wide: give every name the same share and let it truncate
    local gap = h_padding
    local share = math.floor((available - gap * (#self.chapters - 1)) / #self.chapters)
    if share < 1 then share = 1 end
    row, spans = self:buildChapterRow(screen_w, h_padding, face, share)
    return row, spans
end

function LardoView:buildHeader(screen_w, h_padding)
    local small_pad = Size.padding.small
    local header = VerticalGroup:new{ align = "left" }
    table.insert(header, VerticalSpan:new{ width = small_pad })
    table.insert(header, headerRow(screen_w, h_padding, self.title, self.meta,
        Font:getFace("tfont", HEADER_TITLE_SIZE), Font:getFace("cfont", HEADER_LINE_SIZE), true))

    self.chapter_spans = nil
    if #self.chapters > 1 then
        local row, spans = self:buildFittedChapterRow(screen_w, h_padding)
        self.chapter_spans = spans
        table.insert(header, VerticalSpan:new{ width = small_pad })
        table.insert(header, row)
    end
    table.insert(header, VerticalSpan:new{ width = small_pad })
    return header
end

function LardoView:buildButtonRow()
    local row = {}
    local ingredients = self:findChapter("ingredients")
    if ingredients then
        local on_ingredients = ingredients == self.chapter_index
        table.insert(row, {
            text = (on_ingredients and self.ingredients_return) and _("Back")
                or self.chapters[ingredients].title,
            callback = function() self:onLardoIngredients() end,
        })
    end
    if #self.chapters > 1 then
        table.insert(row, {
            text = "<",
            callback = function() self:onLardoChapter("previous") end,
        })
        table.insert(row, {
            text = ">",
            callback = function() self:onLardoChapter("next") end,
        })
    end
    table.insert(row, {
        text = _("Close"),
        callback = function() self:onClose() end,
    })
    return row
end

function LardoView:buildLayout()
    if self.text_widget then
        self.text_widget:free()
    end

    local screen_w, screen_h = self.dimen.w, self.dimen.h
    local h_padding = Size.padding.large
    local bar_thickness = Screen:scaleBySize(4)
    local chapter = self.chapters[self.chapter_index]

    -- also fills in self.chapter_spans, which the segmented bar lines up with
    local header = self:buildHeader(screen_w, h_padding)

    local buttons_h = 0
    self.button_table = nil
    if self.show_buttons then
        self.button_table = ButtonTable:new{
            width = screen_w,
            buttons = { self:buildButtonRow() },
            zero_sep = true,
            show_parent = self,
        }
        buttons_h = self.button_table:getSize().h
        self.layout = self.button_table.layout
    else
        self.layout = nil
    end

    self.progress_line = nil
    local bar_h, side_bar_w = 0, 0
    if self.progress_position == "bottom" or self.progress_position == "top" then
        bar_h = bar_thickness
        self.progress_line = ProgressLine:new{
            width = screen_w,
            height = bar_h,
            -- one span per chapter, aligned with its name above; a recipe with
            -- a single chapter has no chapter row to line up with
            segments = self.chapter_spans,
        }
    elseif self.progress_position == "side" then
        side_bar_w = bar_thickness
    end

    -- the header ends in a hairline; in "top" mode the progress bar sits on it
    local header_group = VerticalGroup:new{ align = "left", header }
    if self.progress_position == "top" and self.progress_line then
        table.insert(header_group, self.progress_line)
    end
    table.insert(header_group, LineWidget:new{
        dimen = Geom:new{ w = screen_w, h = Size.line.thin },
    })
    local header_h = header_group:getSize().h
    self.header_height = header_h -- the touch zone that is chrome rather than text

    local body_h = screen_h - header_h - buttons_h - (self.progress_position == "bottom" and bar_h or 0)
    -- the side bar sits flush against the screen edge, with the padding
    -- between it and the text rather than behind it
    local text_w = screen_w - 2 * h_padding - side_bar_w

    self.text_widget = TextBoxWidget:new{
        text = chapter.text,
        face = self:getBodyFace(),
        width = text_w,
        height = body_h,
        alignment = "left",
        dialog = self,
    }

    local body = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = h_padding },
        self.text_widget,
    }
    if side_bar_w > 0 then
        self.progress_line = ProgressLine:new{
            width = side_bar_w, height = body_h, vertical = true,
        }
        table.insert(body, HorizontalSpan:new{ width = h_padding })
        table.insert(body, self.progress_line)
    end

    local main = VerticalGroup:new{ align = "left" }
    table.insert(main, header_group)
    table.insert(main, body)
    local filler = screen_h - header_h - body:getSize().h - buttons_h
        - (self.progress_position == "bottom" and bar_h or 0)
    if filler > 0 then
        table.insert(main, VerticalSpan:new{ width = filler })
    end
    if self.button_table then
        table.insert(main, self.button_table)
    end
    if self.progress_position == "bottom" and self.progress_line then
        table.insert(main, self.progress_line)
    end

    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        main,
    }
    self:updateProgress()
end

--==========================================================================
-- State
--==========================================================================

function LardoView:findChapter(id)
    for i = 1, #self.chapters do
        if self.chapters[i].id == id then return i end
    end
    return nil
end

function LardoView:updateProgress()
    local _low, high = self.text_widget:getVisibleHeightRatios()
    if high > 1 then high = 1 elseif high < 0 then high = 0 end
    -- remember the furthest point reached, so a chapter you have read stays
    -- filled once you move on
    if high > (self.chapter_progress[self.chapter_index] or 0) then
        self.chapter_progress[self.chapter_index] = high
    end

    if not self.progress_line then return end
    if self.progress_line.segments then
        for i = 1, #self.progress_line.segments do
            -- the chapter being read follows the scroll; the others show how
            -- far they were read
            self.progress_line.segments[i].ratio =
                (i == self.chapter_index) and high or (self.chapter_progress[i] or 0)
        end
    else
        -- single chapter, or the vertical bar: position in the whole recipe
        self.progress_line.percentage = ((self.chapter_index - 1) + high) / #self.chapters
    end
end

function LardoView:refresh()
    self:updateProgress()
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
end

--- Rebuilds for a new chapter, font or setting.
-- @param scroll_to "bottom" to land on the last page (page-back into a chapter)
-- Key bindings do not depend on the current chapter, so they are set up once
-- in init(); changing buttons or fonts reopens the view instead.
--- @param scroll_to "bottom" for the last page, or a line number to return to
function LardoView:rebuild(scroll_to)
    self:buildLayout()
    if scroll_to == "bottom" then
        self.text_widget:scrollToBottom()
    elseif type(scroll_to) == "number" and scroll_to > 1 then
        self.text_widget:scrollLines(scroll_to - self.text_widget.virtual_line_num)
    end
    self:refresh()
end

function LardoView:setChapter(index, scroll_to)
    if index < 1 or index > #self.chapters then return false end
    self.chapter_index = index
    self:rebuild(scroll_to)
    return true
end

--==========================================================================
-- Events
--==========================================================================

function LardoView:onLardoScrollPage(direction)
    local before = self.text_widget.virtual_line_num
    if direction > 0 then
        self.text_widget:scrollDown()
    else
        self.text_widget:scrollUp()
    end
    if self.text_widget.virtual_line_num ~= before then
        self:refresh()
        return true
    end
    -- at the edge of a chapter: turn the page into the next one, like a book
    if direction > 0 then
        self:setChapter(self.chapter_index + 1)
    else
        self:setChapter(self.chapter_index - 1, "bottom")
    end
    return true
end

function LardoView:onLardoScrollLine(direction)
    local before = self.text_widget.virtual_line_num
    self.text_widget:scrollLines(direction)
    if self.text_widget.virtual_line_num ~= before then
        self:refresh()
    end
    return true
end

--- @param target chapter number, "next" or "previous"
function LardoView:onLardoChapter(target)
    if target == "next" then
        target = self.chapter_index < #self.chapters and self.chapter_index + 1 or 1
    elseif target == "previous" then
        target = self.chapter_index > 1 and self.chapter_index - 1 or #self.chapters
    end
    if type(target) == "number" and target ~= self.chapter_index then
        self:setChapter(target)
    end
    return true
end

--- "S" once jumps to the ingredients, "S" again comes back to where you were.
function LardoView:onLardoIngredients()
    local ingredients = self:findChapter("ingredients")
    if not ingredients then return true end

    if self.chapter_index == ingredients then
        local back = self.ingredients_return
        self.ingredients_return = nil
        if back then
            self:setChapter(back.chapter, back.line)
        end
        return true
    end

    self.ingredients_return = {
        chapter = self.chapter_index,
        line = self.text_widget.virtual_line_num,
    }
    self:setChapter(ingredients)
    return true
end

function LardoView:onLardoShowMenu()
    if self.menu_callback then
        self.menu_callback(self)
    end
    return true
end

function LardoView:onLardoNextRecipe()
    if self.next_recipe_callback then
        self.next_recipe_callback()
        return true
    end
    return false
end

function LardoView:onLardoPrevRecipe()
    if self.prev_recipe_callback then
        self.prev_recipe_callback()
        return true
    end
    return false
end

function LardoView:onClose()
    UIManager:close(self)
    if self.close_callback then
        self.close_callback()
    end
    return true
end

function LardoView:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
    return true
end

function LardoView:onCloseWidget()
    if self.text_widget then
        self.text_widget:free()
    end
    UIManager:setDirty(nil, function()
        return "partial", self.dimen
    end)
end

LardoView.ProgressLine = ProgressLine

return LardoView
