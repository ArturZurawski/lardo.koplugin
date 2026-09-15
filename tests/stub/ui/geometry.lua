local Geom = {}
Geom.__index = Geom
function Geom:new(o)
    o = o or {}
    o.w = o.w or 0
    o.h = o.h or 0
    o.x = o.x or 0
    o.y = o.y or 0
    return setmetatable(o, Geom)
end
function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end
return Geom
