local Widget = require("ui/widget/container/widgetcontainer")
-- Enough of Menu's paging/focus model, of MenuItem, and of the footer it lays
-- over the list, to exercise the subclass.
local Menu = Widget:extend{}

local function makeRow(entry)
    return {
        entry = entry,
        font = "smallinfofont",
        font_size = 18,
        init = function(this) this.init_count = (this.init_count or 0) + 1 end,
    }
end

function Menu:init()
    -- Menu hands these to TitleBar as `title_bar_fm_style and <number>`, which
    -- is *false* (not nil) when the flag is false -- and TitleBar multiplies and
    -- adds them. That crashed KOReader at start-up once; it stays caught here.
    assert(self.title_bar_fm_style == nil or self.title_bar_fm_style == true,
        "title_bar_fm_style must be left unset or true, never false")
    self.inited = true
    -- InputContainer:_init gives every instance its own, and Menu:init fills it
    -- with the taps and swipes it wants
    self.ges_events = self.ges_events or {}
    self.page = self.page or 1
    self.perpage = self.perpage or 5
    self.selected = self.selected or { x = 1, y = 1 }

    self.inner_dimen = { x = 0, y = 0, w = 600, h = 800 }
    -- Menu passes TitleBar a close_callback whether the caller wants one or
    -- not, and TitleBar turns that into the ✕ on the right -- in `init`, which
    -- `setTitle` **runs again** whenever the title may change height. That is
    -- what `title_shrink_font_to_fit` asks for, and this list asks for it: so
    -- the ✕ comes back with every new count in that line unless the thing that
    -- builds it is taken away, not just the button.
    local bar = { height = 60, close_callback = function() self:onClose() end }
    function bar:getHeight() return self.height end
    function bar:resetLayout() end
    function bar:init()
        for i = #self, 1, -1 do self[i] = nil end
        self.right_button, self.has_right_icon = nil, false
        if self.close_callback then
            self.right_icon = "close"
            self.has_right_icon = true
            self.right_button = { icon = "close", callback = self.close_callback }
            table.insert(self, self.right_button)
        end
    end
    function bar:setTitle(title)
        self.title = title
        self:init()
    end
    -- TitleBar builds the title with `align = "center"`, so the words sit in the
    -- middle and what is either side of them is empty strip. Their width is the
    -- only thing that tells a tap on them from a tap beside them; ten pixels a
    -- character stands in for measuring the text.
    bar.title_widget = { getWidth = function() return #tostring(self.title or "") * 10 end }
    bar:init()
    self.title_bar = bar
    self.content_group = { self.title_bar }

    self:updateItems(1)
end

function Menu:updateItems(select_number)
    self.item_table = self.item_table or {}
    self.page_num = math.max(1, math.ceil(#self.item_table / self.perpage))
    local first = (self.page - 1) * self.perpage + 1
    local last = math.min(#self.item_table, first + self.perpage - 1)
    self.layout = {}
    for i = first, last do
        table.insert(self.layout, { makeRow(self.item_table[i]) })
    end
    self.selected.y = math.min(select_number or 1, math.max(1, #self.layout))
    -- what Menu does with the title on every update, and what brings the ✕ back
    if self.title_bar.setTitle then self.title_bar:setTitle(self.title) end
end
function Menu:onGotoPage(page)
    self.page = page
    self:updateItems(1)
    return true
end
function Menu:onFocusMove(args)
    self.wrapped_focus_move = true
    local dy = args and args[2]
    if dy and self.selected then
        self.selected.y = math.max(1, math.min(#self.layout, self.selected.y + dy))
    end
    return true
end
function Menu:switchItemTable(title, items, itemnumber, itemmatch, subtitle)
    self.title, self.item_table, self.subtitle = title, items, subtitle
    self.page = 1
    self:updateItems(1)
end
function Menu:onCloseAllMenus()
    self.closed = true
    if self.close_callback then self.close_callback() end
    return true
end
return Menu
