local Dispatcher = { actions = {} }
function Dispatcher:registerAction(name, def) self.actions[name] = def end
return Dispatcher
