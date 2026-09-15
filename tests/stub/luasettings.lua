local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path) return setmetatable({ path = path, data = {}, flushes = 0 }, LuaSettings) end
function LuaSettings:readSetting(k, default)
    if self.data[k] == nil and default ~= nil then self.data[k] = default end
    return self.data[k]
end
function LuaSettings:saveSetting(k, v) self.data[k] = v return self end
function LuaSettings:delSetting(k) self.data[k] = nil return self end
function LuaSettings:isTrue(k) return self.data[k] == true end
function LuaSettings:flush() self.flushes = self.flushes + 1 end
return LuaSettings
