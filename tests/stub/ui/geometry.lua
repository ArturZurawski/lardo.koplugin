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

--- KOReader's: true when the two rectangles do not overlap at all. A tap is a
-- rectangle of no size, which is how "is this tap inside that widget" is asked.
function Geom:notIntersectWith(rect)
    if not rect then return true end
    return self.x > rect.x + rect.w or rect.x > self.x + self.w
        or self.y > rect.y + rect.h or rect.y > self.y + self.h
end

return Geom
