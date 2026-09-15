local Widget = require("ui/widget/container/widgetcontainer")
-- Enough of Menu's paging/focus model, and of MenuItem, to exercise the subclass.
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
    self.page = self.page or 1
    self.perpage = self.perpage or 5
    self.selected = self.selected or { x = 1, y = 1 }
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
end
function Menu:onGotoPage(page)
    self.page = page
    self:updateItems(1)
    return true
end
function Menu:onFocusMove()
    self.wrapped_focus_move = true
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
