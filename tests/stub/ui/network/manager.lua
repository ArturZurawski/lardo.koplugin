local NetworkMgr = { online = true, wifi_on = true, after_action_count = 0,
    when_online_count = 0, when_connected_count = 0 }
function NetworkMgr:isOnline() return self.online end
-- the radio itself, which is what the corner of a recipe follows: it can be on
-- with nothing reachable, and that is still "WiFi is on"
function NetworkMgr:isWifiOn() return self.wifi_on end
-- KOReader drops the callback in runWhenOnline() when the link is up but its
-- DNS check is not; runWhenConnected() always runs it.
function NetworkMgr:runWhenOnline(cb)
    self.when_online_count = self.when_online_count + 1
    if self.online then cb() end
end
function NetworkMgr:runWhenConnected(cb)
    self.when_connected_count = self.when_connected_count + 1
    cb()
end
-- KOReader's "Action when done": it only runs if the caller asks for it
function NetworkMgr:afterWifiAction(cb)
    self.after_action_count = self.after_action_count + 1
    if cb then cb() end
end
return NetworkMgr
