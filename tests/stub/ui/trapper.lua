local Trapper = {}
function Trapper:wrap(fn) return fn() end
function Trapper:info() return true end
function Trapper:clear() end
return Trapper
