local Screen = {}
function Screen:getWidth() return 600 end
function Screen:getHeight() return 800 end
function Screen:getSize() return { w = 600, h = 800 } end
function Screen:scaleBySize(n) return n end

return {
    home_dir = os.getenv("MEALIE_TEST_DIR") or "/tmp/mealie-kotest",
    screen = Screen,
    input = { group = { Back = { "Back" }, PgFwd = { "LPgFwd", "RPgFwd" }, PgBack = { "LPgBack" } } },
    hasKeys = function() return true end,
    hasDPad = function() return true end,
    hasKeyboard = function() return true end,
    hasScreenKB = function() return false end,
    hasFewKeys = function() return false end,
    isTouchDevice = function() return false end,
}
