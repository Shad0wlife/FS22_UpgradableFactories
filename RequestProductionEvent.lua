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
	
	if self.productionPoint ~= nil then
		UFDebug("Received stream request for production data of %s", self.productionPoint:getName())
	else
		UFDebug("[WARNING] Received request for nil production point!!!")
	end
    
    self:run(connection)
end

---
function RequestProductionEvent:writeStream(streamId, connection)
	if self.productionPoint ~= nil then
		UFDebug("Sending stream request for production data of %s", self.productionPoint:getName())
	else
		UFDebug("[WARNING] Sending request for nil production point!!!")
	end

    NetworkUtil.writeNodeObject(streamId, self.productionPoint)
end

---
function RequestProductionEvent:run(connection)
    assert(not connection:getIsServer(), "RequestProductionEvent is client to server only")
    UFInfo("Running RequestProductionEvent.")
    UpgradableFactories.notifyProductionLevel(connection, self.productionPoint)
end

function RequestProductionEvent.sendEvent(productionPoint)
	if productionPoint ~= nil then
		UFDebug("Requesting production data of %s", productionPoint:getName())
	else
		UFDebug("[WARNING] Requesting for nil production point!!!")
	end
	
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(RequestProductionEvent.new(productionPoint))
    end
end