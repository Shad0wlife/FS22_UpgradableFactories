local modDirectory = g_currentModDirectory
local modName = g_currentModName
local xmlFilename = nil

UpgradableFactories = {
	MAX_LEVEL = 10
}

source(modDirectory .. "InGameMenuUpgradableFactories.lua")
source(modDirectory .. "UpgradeProductionEvent.lua")
source(modDirectory .. "RequestProductionEvent.lua")
source(modDirectory .. "ProductionUpgradedEvent.lua")
addModEventListener(UpgradableFactories)

function UFInfo(infoMessage, ...)
	print(string.format("  UpgradableFactories: " .. infoMessage, ...))
end

function UFDebug(debugMessage, ...)
	print(string.format("  [DEBUG] UpgradableFactories: " .. debugMessage, ...))
end

function UpgradableFactories:loadMap()
	self.newSavegame = not g_currentMission.missionInfo.savegameDirectory or nil
	self.loadedProductions = {}
	
	--Only initialize menu on non-dedicated server games
	if g_dedicatedServer == nil then
		UFDebug("loadMap() on non-dedicated game - initializing the menu now.")
		InGameMenuUpgradableFactories:initialize()
	else
		UFDebug("loadMap() on dedicated server does not initialize the menu.")
	end
	
	--Only server does savegame stuff
	if g_currentMission:getIsServer() then
		UFDebug("loadMap() was called by the server.")
		UFInfo("Game is Server -> Get Production levels from Savegame")
		if not self.newSavegame then
			xmlFilename = g_currentMission.missionInfo.savegameDirectory .. "/upgradableFactories.xml"
		end
		self:loadXML()
		
		addConsoleCommand('ufMaxLevel', 'Update UpgradableFactories max level', 'updateml', self)
		g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, self.onSavegameLoaded, self)
	else
		UFDebug("loadMap() was called by the client.")
		UFInfo("Game is Client -> Get Production levels from Sync")
	end
end

function UpgradableFactories:delete()
	g_messageCenter:unsubscribeAll(self)
end




local function getProductionPointFromPosition(pos, farmId)
	UFDebug("Trying to find a production at x=%f, z=%f for farmID %d", pos.x, pos.z, farmId)
	if #g_currentMission.productionChainManager.farmIds < 1 then
		UFDebug("Skipping finding the production since there are no farmIDs defined.")
		return nil
	end
	
	if g_currentMission.productionChainManager.farmIds[farmId] ~= nil then
		UFDebug("FarmID %d exists, checking for production.", farmId)
		for _,prod in ipairs(g_currentMission.productionChainManager.farmIds[farmId].productionPoints) do
			local distance = MathUtil.getPointPointDistanceSquared(pos.x, pos.z, prod.owningPlaceable.position.x, prod.owningPlaceable.position.z)
			UFDebug("Checking production %s at position x=%f, z=%f", prod:getName(), prod.owningPlaceable.position.x, prod.owningPlaceable.position.z)
			if distance < 0.0001 then
				UFDebug("Found production %s at position x=%f, z=%f", prod:getName(), pos.x, pos.z)
				return prod
			end
		end
	end
	UFDebug("Found no production at position x=%f, z=%f", prod:getName(), pos.x, pos.z)
	return nil
end

local function getCapacityAtLvl(capacity, lvl)
	-- Strorage capacity increase by it's base value each level
	return math.floor(capacity * lvl)
end

local function getCycleAtLvl(cycle, lvl)
	-- Production speed increase by it's base value each level.
	-- A bonus of 15% of the base speed is applied per level starting at the level 2
	-- eg. base cycles were 100, factory at lvl 3: 100*3 + 100*0.15*(3-1) = 300 + 100*0.15*2 = 300 + 30 = 330
	lvl = tonumber(lvl)
	local adj = cycle * lvl + cycle * 0.15 * (lvl - 1)
	if adj < 1 then
		return adj
	else
		return math.floor(adj)
	end
end

local function getActiveCostAtLvl(cost, lvl)
	-- Running cost increase by it's base value each level
	-- A reduction of 10% of the base cost is applied par level starting at the level 2
	lvl = tonumber(lvl)
	local adj = cost * lvl - cost * 0.1 * (lvl - 1)
	if adj < 1 then
		return adj
	else
		return math.floor(adj)
	end
end

local function getUpgradePriceAtLvl(basePrice, lvl)
	-- Upgrade price increase by 10% each level
	return math.floor(basePrice + basePrice * 0.1 * lvl)
end

local function getOverallProductionValue(basePrice, lvl)
	-- Base price + all upgrade prices
	local value = 0
	for l=2, lvl do
		value = value + getUpgradePriceAtLvl(basePrice, l-1)
	end
	return basePrice + value
end


-- Formats the Production UI Name to show its level
local function prodPointUFName(basename, level)
	return string.format("%d - %s", level, basename)
end


function UpgradableFactories:upgradeProductionByOne(prodpoint)
	--deduct the upgrade price from the farmId owning the placeable with the prodpoint
	g_currentMission:addMoney(-prodpoint.owningPlaceable.upgradePrice, prodpoint:getOwnerFarmId(), MoneyType.SHOP_PROPERTY_BUY, true, true)
	
	UpgradableFactories:updateProductionPointLevel(prodpoint, prodpoint.productionLevel + 1)
end

function UpgradableFactories:updateProductionPointLevel(prodpoint, lvl)
	prodpoint.productionLevel = lvl
	prodpoint.name = prodPointUFName(prodpoint.baseName, lvl)
	
	for _,prod in ipairs(prodpoint.productions) do
		prod.cyclesPerMinute = getCycleAtLvl(prod.baseCyclesPerMinute, lvl)
		prod.cyclesPerHour = getCycleAtLvl(prod.baseCyclesPerHour, lvl)
		prod.cyclesPerMonth = getCycleAtLvl(prod.baseCyclesPerMonth, lvl)
		
		prod.costsPerActiveMinute = getActiveCostAtLvl(prod.baseCostsPerActiveMinute, lvl)
		prod.costsPerActiveHour = getActiveCostAtLvl(prod.baseCostsPerActiveHour, lvl)
		prod.costsPerActiveMonth = getActiveCostAtLvl(prod.baseCostsPerActiveMonth, lvl)
	end
	
	for ft,s in pairs(prodpoint.storage.baseCapacities) do
		prodpoint.storage.capacities[ft] = getCapacityAtLvl(s, lvl)
	end
	
	prodpoint.owningPlaceable.totalValue = getOverallProductionValue(prodpoint.owningPlaceable.price, lvl)
	prodpoint.owningPlaceable.upgradePrice = getUpgradePriceAtLvl(prodpoint.owningPlaceable.price, lvl)
	prodpoint.owningPlaceable.getSellPrice = function ()
		local priceMultiplier = 0.75
		local maxAge = prodpoint.owningPlaceable.storeItem.lifetime
		if maxAge ~= nil and maxAge ~= 0 then
			priceMultiplier = priceMultiplier * math.exp(-3.5 * math.min(prodpoint.owningPlaceable.age / maxAge, 1))
		end
		return math.floor(prodpoint.owningPlaceable.totalValue * math.max(priceMultiplier, 0.05))
	end
	
	-- Refresh gui only on non-dedicated servers and if the updated production belongs to the own farm
	if g_dedicatedServer == nil and FSBaseMission.player ~= nil and prodpoint:getOwnerFarmId() == FSBaseMission.player.farmId then
		InGameMenuUpgradableFactories:refreshProductionPage()
	end
	
	-- broadCast event doesn't run if this is not a server, that is checked in broadcastEvent itself
	ProductionUpgradedEvent.broadcastEvent(prodpoint, lvl)
end

-- Server only
function UpgradableFactories:onSavegameLoaded()
	UFDebug("onSavegameLoaded() was called. This should only happen on the server.")
	self:initializeLoadedProductions()
end

-- Server only
function UpgradableFactories:initializeLoadedProductions()
	UFDebug("Initializing loaded productions.")
	if self.newSavegame or #self.loadedProductions < 1 then
		UFDebug("initializeLoadedProductions() skipped due to new savegame or no loaded productions.")
		return
	end
	
	UFDebug("Working on %d loaded productions.", #self.loadedProductions)
	for _,loadedProd in ipairs(self.loadedProductions) do
		local prodpoint = getProductionPointFromPosition(loadedProd.position, loadedProd.farmId)
		if prodpoint then
			UFInfo("Initialize loaded production %s [is upgradable: %s]", prodpoint.baseName, prodpoint.isUpgradable)
			UFDebug("If the productions show up here on savegame load, and isUpgradable is false, they need additional initialization.")
			if prodpoint.isUpgradable then
				--prodpoint.productionLevel = loadedProd.level
				--above is done in updateProductionPointLevel
				prodpoint.owningPlaceable.price = loadedProd.basePrice
				prodpoint.owningPlaceable.totalValue = getOverallProductionValue(loadedProd.basePrice, loadedProd.level)
				
				self:updateProductionPointLevel(prodpoint, loadedProd.level)
				
				prodpoint.storage.fillLevels = loadedProd.fillLevels
			end
			
			UFDebug("prodpoint %s has upgradePrice %s", prodpoint:getName(), (prodpoint.owningPlaceable.upgradePrice ~= nil and tostring(prodpoint.owningPlaceable.upgradePrice)) or "nil")
		else
			UFDebug("The loaded production prodpoint was nil.")
		end
	end
end

function UpgradableFactories:initializeProduction(prodpoint)
	--Is automatically called at placement, even during savegame loading.
	if not prodpoint.isUpgradable then
		UFDebug("Initializing prodpoint %s", prodpoint:getName())
	
		prodpoint.isUpgradable = true
		prodpoint.productionLevel = 1
		
		prodpoint.baseName = prodpoint:getName()
		prodpoint.name = prodPointUFName(prodpoint:getName(), 1)
		
		-- prodpoint.owningPlaceable.basePrice = prodpoint.owningPlaceable.price
		prodpoint.owningPlaceable.upgradePrice = getUpgradePriceAtLvl(prodpoint.owningPlaceable.price, 1)
		prodpoint.owningPlaceable.totalValue = prodpoint.owningPlaceable.price
		
		for _,prod in ipairs(prodpoint.productions) do
			prod.baseCyclesPerMinute = prod.cyclesPerMinute
			prod.baseCyclesPerHour = prod.cyclesPerHour
			prod.baseCyclesPerMonth = prod.cyclesPerMonth
			prod.baseCostsPerActiveMinute = prod.costsPerActiveMinute
			prod.baseCostsPerActiveHour = prod.costsPerActiveHour
			prod.baseCostsPerActiveMonth = prod.costsPerActiveMonth
		end
		
		prodpoint.storage.baseCapacities = {}
		for ft,val in pairs(prodpoint.storage.capacities) do
			prodpoint.storage.baseCapacities[ft] = val
		end
		
		--Request production point data from server
		if not g_currentMission:getIsServer() then
			UFDebug("Sending level request event for prodpoint %s", prodpoint:getName())
			RequestProductionEvent.sendEvent(prodpoint)
		end
	end
end

function UpgradableFactories.setOwnerFarmId(prodpoint, farmId)
	if farmId == 0 and prodpoint.productions[1].baseCyclesPerMinute then
		--prodpoint.productionLevel = 1
		--above is done in updateProductionPointLevel
		UpgradableFactories:updateProductionPointLevel(prodpoint, 1)
	end
end

function UpgradableFactories:updateml(arg)
	if not arg then
		print("ufMaxLevel <max_level>")
		return
	end
	
	local n = tonumber(arg)
	if not n then
		print("ufMaxLevel <max_level>")
		print("<max_level> must be a number")
		return
	elseif n < 1 or n > 99 then
		print("ufMaxLevel <max_level>")
		print("<max_level> must be between 1 and 99")
		return
	end
	
	self.MAX_LEVEL = n
	
	self:initializeLoadedProductions()
	
	UFInfo("Production maximum level has been updated to level "..n, "")
end


--This code can be adapted to sync all current productions to a connecting client.
function UpgradableFactories.saveToXML()
	UFInfo("Saving to XML")
	-- on a new save, create xmlFile path
	if g_currentMission.missionInfo.savegameDirectory then
		xmlFilename = g_currentMission.missionInfo.savegameDirectory .. "/upgradableFactories.xml"
	end
	
	local xmlFile = XMLFile.create("UpgradableFactoriesXML", xmlFilename, "upgradableFactories")
	xmlFile:setInt("upgradableFactories#maxLevel", UpgradableFactories.MAX_LEVEL)
	
	-- check if player has owned production installed
	if #g_currentMission.productionChainManager.farmIds > 0 then
		local idx = 0
		for farmId,farmTable in ipairs(g_currentMission.productionChainManager.farmIds) do
			if farmId ~= nil and farmId ~= FarmlandManager.NO_OWNER_FARM_ID and farmId ~= FarmManager.INVALID_FARM_ID then
				local prodpoints = farmTable.productionPoints
				for _,prodpoint in ipairs(prodpoints) do
					if prodpoint.isUpgradable then
						local key = string.format("upgradableFactories.production(%d)", idx)
						xmlFile:setInt(key .. "#id", idx+1) --printed id is 1-indexed, but xml element access is 0-indexed
						xmlFile:setInt(key .. "#farmId", farmId)
						xmlFile:setString(key .. "#name", prodpoint.baseName)
						xmlFile:setInt(key .. "#level", prodpoint.productionLevel)
						xmlFile:setInt(key .. "#basePrice", prodpoint.owningPlaceable.price)
						xmlFile:setInt(key .. "#totalValue", prodpoint.owningPlaceable.totalValue)
						
						local key2 = key .. ".position"
						xmlFile:setFloat(key2 .. "#x", prodpoint.owningPlaceable.position.x)
						xmlFile:setFloat(key2 .. "#y", prodpoint.owningPlaceable.position.y)
						xmlFile:setFloat(key2 .. "#z", prodpoint.owningPlaceable.position.z)
						
						local j = 0
						key2 = ""
						for ft,val in pairs(prodpoint.storage.fillLevels) do
							key2 = key .. string.format(".fillLevels.fillType(%d)", j)
							xmlFile:setString(key2 .. "#fillType", g_currentMission.fillTypeManager:getFillTypeByIndex(ft).name)
							xmlFile:setInt(key2 .. "#fillLevel", val)
							j = j + 1
						end
						idx = idx+1
					end
				end
			end
		end
		
		UFDebug("Saved %d productions to XML.", idx)
		
	end
	xmlFile:save()
end

function UpgradableFactories.notifyProductionLevel(connection, prodpoint)
	
	if prodpoint ~= nil then
		UFDebug("Working on stream request for production data of %s", prodpoint:getName())
	else
		UFDebug("[WARNING] Working on request for nil production point!!!")
	end
	
	if connection == nil then
		UFDebug("[WARNING] Working on request for nil client connection!!!")
	end

	if prodpoint.isUpgradable then
		UFDebug("Replying to client request for production data of %s", prodpoint:getName())
		connection:sendEvent(ProductionUpgradedEvent.new(prodpoint, prodpoint.productionLevel))
	end
end

function UpgradableFactories:loadXML()
	UFInfo("Loading XML...")
	
	if self.newSavegame then
		UFInfo("New savegame")
		return
	end
	
	local xmlFile = XMLFile.loadIfExists("UpgradableFactoriesXML", xmlFilename)
	if not xmlFile then
		UFInfo("No XML file found")
		return
	end
	
	local counter = 0
	while true do
		local key = string.format("upgradableFactories.production(%d)", counter)
		
		if not getXMLInt(xmlFile.handle, key .. "#id") then break end
		
		table.insert(
			self.loadedProductions,
			{
				level = xmlFile:getInt(key .. "#level", 1),
				farmId = xmlFile:getInt(key .. "#farmId", 1),
				name = getXMLString(xmlFile.handle, key .. "#name"),
				basePrice = getXMLInt(xmlFile.handle,key .. "#basePrice"),
				position = {
					x = getXMLFloat(xmlFile.handle, key .. ".position#x"),
					y = getXMLFloat(xmlFile.handle, key .. ".position#y"),
					z = getXMLFloat(xmlFile.handle, key .. ".position#z")
				}
			}
		)
		
		local capacities = {}
		local counter2 = 0
		while true do
			local key2 = key .. string.format(".fillLevels.fillType(%d)", counter2)
			
			local fillTypeName = getXMLString(xmlFile.handle, key2 .. "#fillType")
			if not fillTypeName then 
				break 
			end
			
			local fillTypeIndex = g_currentMission.fillTypeManager:getFillTypeIndexByName(fillTypeName)
			capacities[fillTypeIndex] = getXMLInt(xmlFile.handle, key2 .. "#fillLevel")
			
			counter2 = counter2 +1
		end
		
		self.loadedProductions[counter+1].fillLevels = capacities
		
		counter = counter +1
	end

	local ml = getXMLInt(xmlFile.handle, "upgradableFactories#maxLevel")
	if ml and ml > 0 and ml < 100 then
		self.MAX_LEVEL = ml
	end
	UFInfo(#self.loadedProductions.." productions loaded from XML")
	UFInfo("Production maximum level: "..self.MAX_LEVEL)
	if #self.loadedProductions > 0 then
		for _,p in ipairs(self.loadedProductions) do
			if p.level > self.MAX_LEVEL then
				UFInfo("%s over max level: %d", p.name, p.level)
			end
		end
	end
end


--Placeable addon
function UpgradableFactories.appendedsetLoadingStep(placeable, loadingStep)
	if loadingStep == Placeable.LOAD_STEP_SYNCHRONIZED then
		UFDebug("setLoadingStep of placeable type %s with step %d", placeable.typeName or "no type name", loadingStep)
		SpecializationUtil.raiseEvent(placeable, "onPlaceableSynchronizedUF")
	end
end

function UpgradableFactories.appendedPlaceableEvents(placeableType)
	SpecializationUtil.registerEvent(placeableType, "onPlaceableSynchronizedUF")
end

function UpgradableFactories.appendedPlaceableProductionPointListeners(placeableType)
	SpecializationUtil.registerEventListener(placeableType, "onPlaceableSynchronizedUF", PlaceableProductionPoint)
end

-- Adding and appending to classes

--Handler function first
PlaceableProductionPoint.onPlaceableSynchronizedUF = function(placeableProd)
	UFDebug("PlaceableProductionPoint.onPlaceableSynchronizedUF event handler on production point: %s", placeableProd.spec_productionPoint.productionPoint:getName())
	
	if placeableProd.customEnvironment ~= "pdlc_pumpsAndHosesPack" then
		local spec = placeableProd.spec_productionPoint
		local prodpoint = (spec ~= nil and spec.productionPoint) or nil
	
		if prodpoint ~= nil then
			UFInfo("initialize production %s [has custom env: %s]", prodpoint:getName(), tostring(prodpoint.owningPlaceable.customEnvironment))
			UpgradableFactories:initializeProduction(prodpoint)
		else
			UFInfo("PlaceableProductionPoint without productionPoint is skipped...")
		end
	end
end

--Event raiser and registration next
Placeable.setLoadingStep = Utils.appendedFunction(Placeable.setLoadingStep, UpgradableFactories.appendedsetLoadingStep)
Placeable.registerEvents = Utils.appendedFunction(Placeable.registerEvents, UpgradableFactories.appendedPlaceableEvents)

--register event handler last
PlaceableProductionPoint.registerEventListeners = Utils.appendedFunction(PlaceableProductionPoint.registerEventListeners, UpgradableFactories.appendedPlaceableProductionPointListeners)

--Sync-Unrelated functions
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, UpgradableFactories.saveToXML)
ProductionPoint.setOwnerFarmId = Utils.appendedFunction(ProductionPoint.setOwnerFarmId, UpgradableFactories.setOwnerFarmId)
