local Widget = {}
function Widget:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function Widget:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end
return Widget
