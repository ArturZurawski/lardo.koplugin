--[[--
Full screen recipe list.

A thin Menu subclass: everything device specific (D-pad navigation, page keys,
letter shortcuts for the visible items, "Back" to leave) already comes from
Menu. What we add is the letters going to the filter instead of opening a row,
and a line of chrome at the top that is the filter box and the way to the menu.

@module koplugin.lardo.browser
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local logger = require("logger")
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
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
    --
    -- The title bar has no icons at all: the menu is a tap on that line (or the
    -- Menu key), and the ✕ -- which Menu asks TitleBar for whether we want it or
    -- not -- is taken out in removeTitleBarCloseButton below.
    title_shrink_font_to_fit = true,
    -- the reading font, applied to the rows as well; nil = KOReader's own
    item_font_face = nil,
    item_font_size = nil,
    -- callbacks provided by the plugin
    select_callback = nil,
    -- the line of chrome at the top: its words start the filter, the rest of it
    -- opens KOReader's menu (as does the Menu key)
    menu_button_callback = nil,
    search_button_callback = nil,
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

    -- The two lines below reach into Menu's own furniture -- its title bar, the
    -- geometry of it -- and that furniture differs between KOReader versions.
    -- The list itself does not depend on either: if a version has moved
    -- something, the recipes are still there to read, with one stray icon or one
    -- tap zone missing. Which is a great deal better than a device that will not
    -- start, because at start-up this is the screen.
    local tapped, tap_err = pcall(function() self:registerHeaderTap() end)
    if not tapped then
        logger.warn("Lardo: the header tap could not be set up:", tap_err)
    end

    local ok, err = pcall(function() self:removeTitleBarCloseButton() end)
    if not ok then
        logger.warn("Lardo: the ✕ could not be taken out of the title bar:", err)
    end
end

--- The line of chrome at the top, in two halves: the words, and the rest of it.
--
-- **The words are what they say.** That line is the recipe count, and while you
-- are typing it is the filter box: tapping it starts the filter, which is the
-- one thing the text is about.
--
-- **Beside them is KOReader's menu**, which is where KOReader keeps its own
-- menu on every screen a user has ever used it on. The only reason the habit
-- stops working here is that a full-screen widget of ours covers its touch
-- zone.
--
-- Only the title bar, not the whole screen: below it are the recipes, and a tap
-- on a recipe is how one is opened.
function RecipeBrowser:registerHeaderTap()
    if not Device:isTouchDevice() then return end
    local height = self.title_bar and self.title_bar.getHeight and self.title_bar:getHeight()
    if not height or height <= 0 then return end
    self.ges_events = self.ges_events or {}
    self.ges_events.LardoHeaderTap = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = height },
        },
    }
end

--- Turns the line of chrome into a real field, with a keyboard under it.
--
-- On a device with keys the line already *is* the filter box: the letters go
-- into it and the list narrows between keystrokes. Without keys that was a
-- dialog instead -- a box in the middle of the screen, with the filtering
-- happening only once it was confirmed, which is a different thing wearing the
-- same word. This is the same box the keyboard device has: in the line it is
-- already in, filtering on every letter.
--
-- It sits *over* the title bar rather than replacing it. Menu measures its own
-- furniture to lay the list out, and a widget swapped into that furniture is
-- how several of the uglier bugs in this plugin's history began.
-- @param text what to start with
-- @param on_edit called with the text after every keystroke
-- @param on_done called when the field is put away
-- @return true if the field is up
function RecipeBrowser:showFilterField(text, on_edit, on_done)
    if self.filter_field then return true end
    self.filter_done_callback = on_done
    local ok, err = pcall(function()
        local input
        input = InputText:new{
            text = text or "",
            hint = _("Filter recipes"),
            face = Font:getFace(DEFAULT_ITEM_FONT),
            width = Screen:getWidth() - 4 * Size.padding.default,
            -- InputText calls this from its own constructor ("false on init"),
            -- before `new` has returned and before anything here can have a
            -- reference to the widget. So: only once there is one.
            edit_callback = function()
                if input and on_edit then on_edit(input:getText()) end
            end,
            -- the one visible way out that every keyboard layout has
            enter_callback = function() self:closeFilterField() end,
        }
        -- ...and the other one: backspacing when there is nothing left to
        -- delete. It is how the filter is left on a keyboard device, and the
        -- second press of a key that is already in the hand.
        local delChar = input.delChar
        input.delChar = function(this, ...)
            if this:getText() == "" then
                self:closeFilterField()
                return
            end
            return delChar(this, ...)
        end
        local field = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding = Size.padding.default,
            input,
        }
        -- The strip sits at the top of a catcher the size of the screen: with
        -- the keyboard up there is nothing else to do on this screen, so a tap
        -- anywhere that is not the field itself puts it away. Children are
        -- asked first, so a tap *on* the field still goes to the field --
        -- moving the cursor, not closing the thing you are typing into.
        local catcher = InputContainer:new{
            dimen = Screen:getSize(),
            -- The keyboard is the topmost widget while it is up, and
            -- `UIManager:sendEvent` offers an event the topmost widget did not
            -- consume **only** to widgets flagged like this ("widgets that want
            -- to show a VirtualKeyboard"). Without it a tap outside the
            -- keyboard reaches nothing at all, which is what it did.
            is_always_active = true,
            field,
        }
        catcher.ges_events = {
            LardoCloseFilterField = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
                    },
                },
            },
        }
        catcher.onLardoCloseFilterField = function(_catcher, _arg, ges)
            -- A tap can land in the grey between two keys, which is a miss on
            -- the keyboard rather than a tap outside it -- and, being a miss,
            -- it falls through to us. KOReader's own dialog checks the same
            -- thing before putting its keyboard away.
            local keyboard = input.keyboard
            if ges and ges.pos and keyboard and keyboard.dimen
                    and ges.pos.notIntersectWith
                    and not ges.pos:notIntersectWith(keyboard.dimen) then
                return false
            end
            self:closeFilterField()
            return true
        end
        input.parent = catcher -- what InputText marks dirty as it is typed into
        self.filter_field, self.filter_input = catcher, input
        UIManager:show(catcher, nil, nil, 0, 0) -- the top of the screen: this line
        input:onShowKeyboard()
    end)
    if not ok then
        logger.warn("Lardo: the filter field could not be opened:", err)
        self.filter_field, self.filter_input = nil, nil
    end
    return ok
end

--- @return whether there was a field to close
function RecipeBrowser:closeFilterField()
    local field, input = self.filter_field, self.filter_input
    local done = self.filter_done_callback
    self.filter_field, self.filter_input, self.filter_done_callback = nil, nil, nil
    if not field then return false end
    pcall(function()
        if input.onCloseKeyboard then input:onCloseKeyboard() end
        UIManager:close(field)
    end)
    if done then done() end
    return true
end

--- Whether a tap landed on the title's own words.
--
-- `Menu` builds its title bar with `align = "center"`, so the text sits in the
-- middle of the strip and what is either side of it is empty. Ask the widget
-- how wide it is rather than guess: the line is a count one moment and what you
-- have typed the next, and it is drawn in the reading font, which is a setting.
function RecipeBrowser:tappedTheTitle(ges)
    local x = ges and ges.pos and ges.pos.x
    local widget = self.title_bar and self.title_bar.title_widget
    local width = widget and widget.getWidth and widget:getWidth()
    if not x or not width or width <= 0 then return false end
    local from = (Screen:getWidth() - width) / 2
    return x >= from and x <= from + width
end

function RecipeBrowser:onLardoHeaderTap(_arg, ges)
    if self:tappedTheTitle(ges) and self.search_button_callback then
        self.search_button_callback()
    elseif self.menu_button_callback then
        self.menu_button_callback()
    end
    return true
end

--- Takes the ✕ out of the title bar.
--
-- `Menu:init` hands `TitleBar` a `close_callback` whether we want one or not,
-- and `TitleBar` turns that into the right hand icon -- so leaving
-- `title_bar_left_icon` unset removed the ☰ and left the ✕ behind. That ✕ is
-- wired to `onClose()`, which on the recipe list is the key that deliberately
-- does nothing (Back must not drop you out of a recipe mid-cooking), so it
-- looked like the way out and was not one. Rewiring its callback did not help
-- either. It is gone: the way out is *Close Lardo* in the menu, which says so.
function RecipeBrowser:removeTitleBarCloseButton()
    local bar = self.title_bar
    if not bar then return end
    -- The cause, before the button. `TitleBar:init()` turns a `close_callback`
    -- into the right hand icon, and `setTitle` **runs that whole init again**
    -- whenever the title may change height -- which is exactly what
    -- `title_shrink_font_to_fit` asks for, and this list asks for it. Taking
    -- only the button away therefore worked once, and the first new count in
    -- that line ("7 recipes in Mealie") put the ✕ straight back.
    bar.close_callback = nil
    bar.close_hold_callback = nil
    bar.right_icon = nil
    bar.right_icon_tap_callback = nil
    -- TitleBar checks both of these before touching the button again
    -- (setRightIcon, generateVerticalLayout), so neither may be left behind.
    bar.has_right_icon = false
    if bar.right_button then
        for i = #bar, 1, -1 do
            if bar[i] == bar.right_button then
                table.remove(bar, i)
            end
        end
        bar.right_button = nil
    end
    if bar.resetLayout then bar:resetLayout() end
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
    -- A face is a typeface *at a size*, and only Menu's own rows carry one. Ask
    -- for one without it and KOReader looks the name up in its fontmap, where a
    -- font file path is never a key, and scales the nil it finds.
    if not widget.font_size then return end
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
    -- opening a recipe is leaving the list: the field and its keyboard have no
    -- business over the top of it
    self:closeFilterField()
    if item and item.recipe and self.select_callback then
        self.select_callback(item.recipe)
    end
    return true
end

--- Leaving the list takes the field with it, wherever the leaving came from.
function RecipeBrowser:onCloseAllMenus()
    self:closeFilterField()
    if Menu.onCloseAllMenus then return Menu.onCloseAllMenus(self) end
    return true
end

function RecipeBrowser:onMenuHold(item)
    return self:onMenuSelect(item)
end

--- KOReader's Menu wraps the focus around inside the current page, so holding
-- Down on a long list (every installed font, hundreds of recipes) never leaves
-- the first page. Step onto the neighbouring page at the edges instead.
--- Walking off the grid turns the page, in the direction it was walked off in.
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
