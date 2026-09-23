local reader_order = require("ui/elements/reader_menu_order")
local filemanager_order = require("ui/elements/filemanager_menu_order")

-- KOReader's own, and the one call a contributed plugin makes at load time to
-- appear under Tools -> More tools. Being in the *order* is what makes
-- MenuSorter place an entry rather than sweep it up as an orphan afterwards.
local PluginMenuInserter = {}

function PluginMenuInserter.add(name)
    table.insert(reader_order.more_tools, name)
    table.insert(filemanager_order.more_tools, name)
end

return PluginMenuInserter
