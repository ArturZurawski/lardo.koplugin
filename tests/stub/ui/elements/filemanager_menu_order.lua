-- KOReader's menu order: the row of tabs, and what goes in each of them. A
-- module, so `require` hands everybody the same table -- which is what lets a
-- plugin add a tab of its own to the row, and what `insert_menu` appends to.
--
-- `tools` ends with `more_tools`, a section of its own: that nesting is where
-- every contributed plugin lives, so the stub has it too.
return {
    ["KOMenu:menu_buttons"] = {
        "filemanager_settings",
        "setting",
        "tools",
        "search",
        "main",
    },
    tools = { "----------------------------", "more_tools" },
    more_tools = { "plugin_management" },
}
