local UIManager = { shown = {}, ticks = {} }
function UIManager:show(w) table.insert(self.shown, w) end
function UIManager:close(w) for i = #self.shown, 1, -1 do if self.shown[i] == w then table.remove(self.shown, i) end end end
function UIManager:nextTick(fn) table.insert(self.ticks, fn) end
function UIManager:runTicks() local t = self.ticks; self.ticks = {}; for _i = 1, #t do t[_i]() end end
function UIManager:forceRePaint() end
function UIManager:setDirty() end
function UIManager:scheduleIn() end
return UIManager
