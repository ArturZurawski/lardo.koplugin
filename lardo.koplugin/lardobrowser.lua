--[[--
Full screen recipe list.

A thin Menu subclass: everything device specific (D-pad navigation, page keys,
letter shortcuts for the visible items, "Back" to leave) already comes from
Menu; we only redirect selection and the title bar button back to the plugin.

@module koplugin.lardo.browser
--]]

local Device = require("device")
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local _ = require("lardoi18n").gettext

-- MenuItem's own default; what we restore to if a preview font will not load.
local DEFAULT_ITEM_FONT = "smallinfofont"

local RecipeBrowser = Menu:extend{
    title = _("Lardo"),
    is_popout = false,
    is_borderless = true,
    -- Menu does not set this, every full screen user of it does (FileManager's
    -- BookList, the collections, the book map...). It is what tells
    -- UIManager:_repaint() that nothing below us is worth painting -- and below
    -- us there is always the file manager, because that is what Lardo opens on
    -- top of. Without it every repaint of the list, and in particular the one
    -- after the screensaver goes away, drew the whole file browser first.
    covers_fullscreen = true,
    -- title_bar_fm_style is deliberately NOT set here, and must never be set to
    -- false: Menu passes it on as `self.title_bar_fm_style and <number>`, which
    -- for false yields *false*, and TitleBar then does arithmetic on it
    -- (left_icon_size_ratio, button_padding) and dies taking KOReader with it.
    -- Left unset it is nil, which is what we want twice over: TitleBar falls
    -- back to its own numbers, and Menu no longer forces an empty subtitle line
    -- -- and that saved line is one more recipe on the page.
    title_bar_left_icon = "appbar.menu",
    title_shrink_font_to_fit = true,
    -- the reading font, applied to the rows as well; nil = KOReader's own
    item_font_face = nil,
    item_font_size = nil,
    -- callbacks provided by the plugin
    select_callback = nil,
    menu_button_callback = nil,
    -- typing filters the list: filter_callback(character) for every letter,
    -- "backspace" for Del; clear_filter_callback() returns true if there was a
    -- filter to clear. Given only by the recipe list -- the typeface picker
    -- keeps Menu's letter shortcuts, which is how you cross 300 fonts.
    filter_callback = nil,
    clear_filter_callback = nil,
    -- the recipe list is left through its own menu, not with Back
    keep_open_on_back = false,
}

--- The Kindle keyboard, in its own order; Menu uses the same list for its
-- shortcut icons ("Del" is the backspace key, next to L).
local FILTER_LETTERS = {
    "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P",
    "A", "S", "D", "F", "G", "H", "J", "K", "L",
    "Z", "X", "C", "V", "B", "N", "M",
}

--- Rows per page for a given reading font size, so that the size the user
-- picked is the size they get: Menu caps a row's font to what fits in its
-- height, and the height is the page divided by the number of rows. This is
-- KOReader's own size-per-page formula (Menu.getItemFontSize) inverted.
local function itemsPerPage(font_size)
    local perpage = math.floor(6 + (24 - font_size) * 1.8 + 0.5)
    if perpage < 5 then return 5 elseif perpage > 30 then return 30 end
    return perpage
end

--- Feeds the reading font into Menu's own fields. Menu re-reads both in
-- _recalculateDimen() on every updateItems(), so this also works on an open
-- list.
function RecipeBrowser:applyItemFont()
    if self.item_font_size then
        self.items_font_size = self.item_font_size
        self.items_per_page = itemsPerPage(self.item_font_size)
    end
end

function RecipeBrowser:init()
    self:applyItemFont()
    if self.filter_callback then
        -- the letters type into the filter now, so their "press Q to open the
        -- first row" icons would be a lie
        self.is_enable_shortcut = false
    end
    Menu.init(self)
    self:registerKeyEvents() -- Menu:init() calls this too; doing it twice is free

    -- Back stays inside the list (see onClose below), but the X in the title bar
    -- is a deliberate tap, and on a touch screen it is the way out. Menu wires
    -- it to onClose; rewire the button itself, which is what gets tapped.
    if self.keep_open_on_back and self.title_bar and self.title_bar.right_button then
        self.title_bar.right_button.callback = function() self:onCloseAllMenus() end
    end
end

--- Letters go to the filter instead of selecting a row. This is the whole
-- interaction on a keyboard device: type, and the list narrows as you go.
function RecipeBrowser:registerKeyEvents()
    if Menu.registerKeyEvents then
        Menu.registerKeyEvents(self)
    end
    if not self.filter_callback or not Device:hasKeyboard() then return end
    self.key_events = self.key_events or {}
    self.key_events.LardoFilterLetter = { { FILTER_LETTERS } }
    self.key_events.LardoFilterSpace = { { "Space" } }
    self.key_events.LardoFilterDot = { { "." } }
    self.key_events.LardoFilterBackspace = { { "Del" } }
end

function RecipeBrowser:onLardoFilterLetter(_, keyevent)
    local key = keyevent and keyevent.key
    if type(key) == "string" and #key == 1 then
        self.filter_callback(key:lower())
    end
    return true
end

function RecipeBrowser:onLardoFilterSpace()
    self.filter_callback(" ")
    return true
end

function RecipeBrowser:onLardoFilterDot()
    self.filter_callback(".")
    return true
end

function RecipeBrowser:onLardoFilterBackspace()
    self.filter_callback("backspace")
    return true
end

--- Back clears the filter, and otherwise does nothing at all on the recipe
-- list: leaving Lardo is a deliberate menu action ("Close Lardo"), not
-- something a stray key press in a kitchen should manage. The typeface picker
-- keeps the usual behaviour -- it is a picker, and Back is how you leave one.
function RecipeBrowser:onClose()
    if self.clear_filter_callback and self.clear_filter_callback() then
        return true
    end
    if self.keep_open_on_back then
        return true
    end
    if Menu.onClose then
        return Menu.onClose(self)
    end
    return self:onCloseAllMenus()
end

--- Changes the font of an already visible list.
function RecipeBrowser:setItemFont(font_face, font_size)
    self.item_font_face = font_face
    self.item_font_size = font_size
    self:applyItemFont()
    self:updateItems(1)
end

--- Menu marks the row under the cursor with a hairline underline, which is
-- easy to lose on a 16-grey screen. Invert the whole row instead, so it reads
-- as a selection bar.
local function makeRowInvertOnFocus(row_widget)
    if row_widget._lardo_focus_patched then return end
    row_widget._lardo_focus_patched = true

    local paintTo = row_widget.paintTo
    row_widget.paintTo = function(this, bb, x, y)
        if paintTo then
            paintTo(this, bb, x, y)
        end
        if this._lardo_focused and this.dimen then
            bb:invertRect(this.dimen.x, this.dimen.y, this.dimen.w, this.dimen.h)
        end
    end

    local onFocus, onUnfocus = row_widget.onFocus, row_widget.onUnfocus
    row_widget.onFocus = function(this, ...)
        this._lardo_focused = true
        if onFocus then return onFocus(this, ...) end
        return true
    end
    row_widget.onUnfocus = function(this, ...)
        this._lardo_focused = false
        if onUnfocus then return onUnfocus(this, ...) end
        return true
    end
end

--- Draws a row in a given font: the typeface list previews each font in itself,
-- and the recipe list uses the typeface picked for reading. Menu has no
-- per-item face, but MenuItem takes `font`, which Font:getFace() accepts as a
-- file path just as well as a fontmap name, and MenuItem:init() is idempotent
-- -- so setting it and rebuilding the row is enough.
local function applyRowFont(widget, font_file)
    if not font_file or widget.font == font_file then return end
    if not Font:getFace(font_file, widget.font_size) then
        return -- KOReader lists it but cannot load it; leave the row readable
    end
    local ok = pcall(function()
        widget.font = font_file
        widget:init()
    end)
    if not ok then
        widget.font = DEFAULT_ITEM_FONT
        pcall(widget.init, widget)
    end
end

function RecipeBrowser:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    if not self.layout then return end
    for y = 1, #self.layout do
        for x = 1, #self.layout[y] do
            local widget = self.layout[y][x]
            local entry = widget.entry
            applyRowFont(widget, (entry and entry.preview_font) or self.item_font_face)
        end
    end
    if not Device:hasDPad() then return end
    -- Menu focuses an item while building the page, i.e. before we get here,
    -- so set the state from self.selected rather than trusting the events.
    local selected = self.selected or { x = 1, y = 1 }
    local focused = self.layout[selected.y] and self.layout[selected.y][selected.x]
    for y = 1, #self.layout do
        local row = self.layout[y]
        for x = 1, #row do
            makeRowInvertOnFocus(row[x])
            row[x]._lardo_focused = row[x] == focused
        end
    end
end

function RecipeBrowser:onMenuSelect(item)
    if item and item.recipe and self.select_callback then
        self.select_callback(item.recipe)
    end
    return true
end

function RecipeBrowser:onMenuHold(item)
    return self:onMenuSelect(item)
end

--- KOReader's Menu wraps the focus around inside the current page, so holding
-- Down on a long list (every installed font, hundreds of recipes) never leaves
-- the first page. Step onto the neighbouring page at the edges instead.
function RecipeBrowser:onFocusMove(args)
    local dy = args and args[2]
    if dy and dy ~= 0 and self.layout and self.selected and self.page_num then
        if dy > 0 and self.selected.y >= #self.layout and self.page < self.page_num then
            self:onGotoPage(self.page + 1) -- lands on the first item
            return true
        elseif dy < 0 and self.selected.y <= 1 and self.page > 1 then
            self:onGotoPage(self.page - 1)
            self:updateItems(#self.layout, true) -- ...and here on the last one
            return true
        end
    end
    return Menu.onFocusMove(self, args)
end

--- Bound to the "Menu" key by Menu:registerKeyEvents().
function RecipeBrowser:onLeftButtonTap()
    if self.menu_button_callback then
        self.menu_button_callback()
    end
    return true
end

return RecipeBrowser
