RequestProductionEvent = {}
local RequestProductionEvent_mt = Class(RequestProductionEvent, Event)
InitEventClass(RequestProductionEvent, "RequestProductionEvent")

---
function RequestProductionEvent.emptyNew()
    local self = Event.new(RequestProductionEvent_mt)
    return self
end

---
function RequestProductionEvent.new(productionPoint)
    local self = RequestProductionEvent.emptyNew()
    
    self.productionPoint = productionPoint

    return self
end

---
function RequestProductionEvent:readStream(streamId, connection)
    self.productionPoint = NetworkUtil.readNodeObject(streamId)
    
    self:run(connection)
end

---
function RequestProductionEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.productionPoint)
end

---
function RequestProductionEvent:run(connection)
    assert(not connection:getIsServer(), "RequestProductionEvent is client to server only")
    UFInfo("Running RequestProductionEvent.")
    UpgradableFactories.notifyProductionLevel(connection, self.productionPoint)
end

function RequestProductionEvent.sendEvent(productionPoint)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(RequestProductionEvent.new(productionPoint))
    end
end