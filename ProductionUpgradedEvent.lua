ProductionUpgradedEvent = {}
local ProductionUpgradedEvent_mt = Class(ProductionUpgradedEvent, Event)
InitEventClass(ProductionUpgradedEvent, "ProductionUpgradedEvent")

---
function ProductionUpgradedEvent.emptyNew()
    local self = Event.new(ProductionUpgradedEvent_mt)
    return self
end

---
function ProductionUpgradedEvent.new(productionPoint, toLevel)
    local self = ProductionUpgradedEvent.emptyNew()
    
    self.productionPoint = productionPoint
    self.toLevel = toLevel

    return self
end

---
function ProductionUpgradedEvent:readStream(streamId, connection)
    self.productionPoint = NetworkUtil.readNodeObject(streamId)
    self.toLevel = streamReadInt32(streamId)
    
    self:run(connection)
end

---
function ProductionUpgradedEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.productionPoint)
    streamWriteInt32(streamId, self.toLevel)
end

---
function ProductionUpgradedEvent:run(connection)
    assert(not connection:getIsClient(), "ProductionUpgradedEvent is server to client only")
    UFInfo("Running ProductionUpgradedEvent.")
    UpgradableFactories.updateProductionPointLevel(self.productionPoint, self.toLevel)
end

function ProductionUpgradedEvent.broadcastEvent(productionPoint, toLevel)
    -- Is Server only
    if g_currentMission:getIsServer() then
        --use server:broadcastEvent(event, sendLocal) with sendLocal = false,
        --since the local upgrade is what kicks of this event in the first place
        UFInfo("Broadcasting ProductionUpgradedEvent.")
        g_server:broadcastEvent(ProductionUpgradedEvent.new(productionPoint, toLevel), false)
    end
end