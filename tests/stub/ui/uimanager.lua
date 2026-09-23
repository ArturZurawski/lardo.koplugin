local UIManager = { shown = {}, ticks = {}, scheduled = {} }
function UIManager:show(w) table.insert(self.shown, w) end
function UIManager:close(w) for i = #self.shown, 1, -1 do if self.shown[i] == w then table.remove(self.shown, i) end end end
function UIManager:nextTick(fn) table.insert(self.ticks, fn) end
function UIManager:setDirty() end
-- The keep-awake nudge lives here: a task that reschedules itself, so a test
-- has to be able to see what is waiting and for how long, and to run it.
function UIManager:scheduleIn(seconds, fn)
    table.insert(self.scheduled, { seconds = seconds, fn = fn })
end
function UIManager:unschedule(fn)
    for i = #self.scheduled, 1, -1 do
        if self.scheduled[i].fn == fn then table.remove(self.scheduled, i) end
    end
end
function UIManager:runScheduled()
    local due = self.scheduled
    self.scheduled = {}
    for i = 1, #due do due[i].fn() end
end
return UIManager
