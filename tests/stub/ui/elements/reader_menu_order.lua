-- The reader's menu order. A plugin that adds itself with `insert_menu` lands
-- in both this and the file manager's, which is why the stub has to exist:
-- without it the require fails and the whole mechanism goes untested.
return {
    ["KOMenu:menu_buttons"] = { "navi", "typeset", "setting", "tools", "search", "main" },
    tools = { "----------------------------", "more_tools" },
    more_tools = { "plugin_management" },
}
