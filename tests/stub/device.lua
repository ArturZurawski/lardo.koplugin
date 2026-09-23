local Screen = {}
function Screen:getWidth() return 600 end
function Screen:getHeight() return 800 end
function Screen:getSize() return { w = 600, h = 800 } end
function Screen:scaleBySize(n) return n end

-- A Kindle's screensaver timer lives in its firmware; KindlePowerD pokes it
-- through lipc, and this stands in for that.
local PowerD = {
    capacity = 75,
    charging = false,
    t1_resets = 0,
}
function PowerD:getCapacity() return self.capacity end
function PowerD:isCharging() return self.charging end
function PowerD:isCharged() return false end
function PowerD:resetT1Timeout() self.t1_resets = self.t1_resets + 1 end

return {
    home_dir = os.getenv("MEALIE_TEST_DIR") or "/tmp/mealie-kotest",
    powerd = PowerD,
    getPowerDevice = function(self) return self.powerd end,
    hasBattery = function() return true end,
    screen = Screen,
    input = { group = { Back = { "Back" }, PgFwd = { "LPgFwd", "RPgFwd" }, PgBack = { "LPgBack" } } },
    hasKeys = function() return true end,
    hasDPad = function() return true end,
    hasKeyboard = function() return true end,
    hasScreenKB = function() return false end,
    hasFewKeys = function() return false end,
    isTouchDevice = function() return false end,
}
