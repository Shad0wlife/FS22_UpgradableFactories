UpdateProductionEvent = {}
local UpdateProductionEvent_mt = Class(UpdateProductionEvent, Event)
InitEventClass(UpdateProductionEvent, "UpdateProductionEvent")

---
function UpdateProductionEvent.emptyNew()
    local self = Event.new(UpdateProductionEvent_mt)
    return self
end

---
function UpdateProductionEvent.new(productionPoint)
    local self = UpdateProductionEvent.emptyNew()
    
    self.productionPoint = productionPoint

    return self
end

---
function UpdateProductionEvent:readStream(streamId, connection)
    self.productionPoint = NetworkUtil.readNodeObject(streamId)
    
    self:run(connection)
end

---
function UpdateProductionEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.productionPoint)
end

---
function UpdateProductionEvent:run(connection)
    assert(not connection:getIsServer(), "UpdateProductionEvent is client to server only")
    UFInfo("Running UpdateProductionEvent.")
    UpgradableFactories.upgradeProductionByOne(self.productionPoint)
end

function UpdateProductionEvent.sendEvent(productionPoint)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(UpdateProductionEvent.new(productionPoint))
    end
end