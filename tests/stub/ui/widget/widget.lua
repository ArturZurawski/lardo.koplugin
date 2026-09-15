local Widget = {}
function Widget:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function Widget:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function Widget:getSize() return self.dimen or { w = 0, h = 0 } end
function Widget:free() end
function Widget:paintTo() end
return Widget
