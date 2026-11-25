local Dispatcher = { actions = {} }
-- like KOReader's: a name it already has is ignored
function Dispatcher:registerAction(name, def)
    if self.actions[name] == nil then self.actions[name] = def end
end
function Dispatcher:removeAction(name) self.actions[name] = nil end
return Dispatcher
