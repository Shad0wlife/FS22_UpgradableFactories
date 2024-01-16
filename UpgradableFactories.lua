local modDirectory = g_currentModDirectory
local modName = g_currentModName
local xmlFilename = nil

UpgradableFactories = {
	MAX_LEVEL = 10
}

source(modDirectory .. "InGameMenuUpgradableFactories.lua")
source(modDirectory .. "UpgradeProductionEvent.lua")
source(modDirectory .. "ProductionUpgradedEvent.lua")
addModEventListener(UpgradableFactories)

function UFInfo(infoMessage, ...)
	print(string.format("  UpgradableFactories: " .. infoMessage, ...))
end

function UpgradableFactories:loadMap()
	self.newSavegame = not g_currentMission.missionInfo.savegameDirectory or nil
	self.loadedProductions = {}
	
	if g_dedicatedServer == nil then
		InGameMenuUpgradableFactories:initialize()
	else
		UFInfo("Dedicated Server detected. Skipping menu init.")
	end
	
	--Only server does savegame stuff
	if g_currentMission:getIsServer() then
		UFInfo("Game is Server -> Get Production levels from Savegame")
		if not self.newSavegame then
			xmlFilename = g_currentMission.missionInfo.savegameDirectory .. "/upgradableFactories.xml"
		end
		self:loadXML()
		
		addConsoleCommand('ufMaxLevel', 'Update UpgradableFactories max level', 'updateml', self)
		g_messageCenter:subscribe(MessageType.SAVEGAME_LOADED, self.onSavegameLoaded, self)
	else
		UFInfo("Game is Client -> Get Production levels from Sync")
	end
end

function UpgradableFactories:delete()
	g_messageCenter:unsubscribeAll(self)
end




local function getProductionPointFromPosition(pos, farmId)
	if #g_currentMission.productionChainManager.farmIds < 1 then
		return nil
	end
	
	if g_currentMission.productionChainManager.farmIds[farmId] ~= nil then
		for _,prod in pairs(g_currentMission.productionChainManager.farmIds[farmId].productionPoints) do
			if MathUtil.getPointPointDistanceSquared(pos.x, pos.z, prod.owningPlaceable.position.x, prod.owningPlaceable.position.z) < 0.0001 then
				return prod
			end
		end
	end
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


function UpgradableFactories.upgradeProductionByOne(prodpoint)
	--deduct the upgrade price from the farmId owning the placeable with the prodpoint
	g_currentMission:addMoney(-prodpoint.owningPlaceable.upgradePrice, prodpoint:getOwnerFarmId(), MoneyType.SHOP_PROPERTY_BUY, true, true)
	
	UpgradableFactories.updateProductionPointLevel(prodpoint, prodpoint.productionLevel + 1)
end

function UpgradableFactories.updateProductionPointLevel(prodpoint, lvl)
	prodpoint.productionLevel = lvl
	prodpoint.name = prodPointUFName(prodpoint.baseName, lvl)
	
	for _,prod in pairs(prodpoint.productions) do
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
	self:initializeLoadedProductions()
end

-- Server only
function UpgradableFactories:initializeLoadedProductions()
	if self.newSavegame or #self.loadedProductions < 1 then
		return
	end
	
	for _,loadedProd in ipairs(self.loadedProductions) do
		local prodpoint = getProductionPointFromPosition(loadedProd.position, loadedProd.farmId)
		if prodpoint then
			UFInfo("Initialize loaded production %s [is upgradable: %s]", prodpoint.baseName, prodpoint.isUpgradable)
			if prodpoint.isUpgradable then
				--prodpoint.productionLevel is set in updateProductionPointLevel
				prodpoint.owningPlaceable.price = loadedProd.basePrice
				prodpoint.owningPlaceable.totalValue = getOverallProductionValue(loadedProd.basePrice, loadedProd.level)
				
				self.updateProductionPointLevel(prodpoint, loadedProd.level)
				
				prodpoint.storage.fillLevels = loadedProd.fillLevels
			end
		end
	end
end

function UpgradableFactories:initializeProduction(prodpoint)
	if not prodpoint.isUpgradable then
		prodpoint.isUpgradable = true
		prodpoint.productionLevel = 1
		
		prodpoint.baseName = prodpoint:getName()
		prodpoint.name = prodPointUFName(prodpoint:getName(), 1)
		
		-- prodpoint.owningPlaceable.basePrice = prodpoint.owningPlaceable.price
		prodpoint.owningPlaceable.upgradePrice = getUpgradePriceAtLvl(prodpoint.owningPlaceable.price, 1)
		prodpoint.owningPlaceable.totalValue = prodpoint.owningPlaceable.price
		
		for _,prod in pairs(prodpoint.productions) do
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
	end
end

function UpgradableFactories.onFinalizePlacement(placeableProduction)
	if placeableProduction.customEnvironment ~= "pdlc_pumpsAndHosesPack" then
		local spec = placeableProduction.spec_productionPoint
		local prodpoint = (spec ~= nil and spec.productionPoint) or nil
	
		if prodpoint ~= nil then
			UFInfo("initialize production %s [has custom env: %s]", prodpoint:getName(), tostring(prodpoint.owningPlaceable.customEnvironment))
			UpgradableFactories:initializeProduction(prodpoint)
		else
			UFInfo("PlaceableProductionPoint without productionPoint is skipped...")
		end
	end
end

function UpgradableFactories.setOwnerFarmId(prodpoint, farmId)
	if farmId == 0 and prodpoint.productions[1].baseCyclesPerMinute then
		--productionLevel is reset to 1 in updateProductionPointLevel
		UpgradableFactories.updateProductionPointLevel(prodpoint, 1)
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
	
	-- check if the game has any farmIds that have productions
	if #g_currentMission.productionChainManager.farmIds > 0 then
		local idx = 0
		-- iterate over all (player-)farmIDs and their productions
		-- needs to use pairs() and not ipairs() since ipairs stops when an id is missing (as in: a farm has no productions)
		for farmId,farmTable in pairs(g_currentMission.productionChainManager.farmIds) do
			if tonumber(farmId) ~= nil then
				if farmId ~= nil and farmId ~= FarmlandManager.NO_OWNER_FARM_ID and farmId ~= FarmManager.INVALID_FARM_ID then
					local prodpoints = farmTable.productionPoints
					for _,prodpoint in pairs(prodpoints) do
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
		end
		
	end
	xmlFile:save()
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

--Stream prefix functions for initial sync
function UpgradableFactories.prodpointWriteStream(prodpoint, streamId, connection)
	-- WriteStream only on connections to a client
	if not connection:getIsServer() then
		local level = prodpoint.productionLevel or 1

		streamWriteInt32(streamId, level)
	end
end

function UpgradableFactories.prodpointReadStream(prodpoint, streamId, connection)
	-- ReadStream only from connections to a server
	if connection:getIsServer() then
		local level = streamReadInt32(streamId)
		
		if prodpoint.isUpgradable then
			UpgradableFactories.updateProductionPointLevel(prodpoint, level)
		end
	end
end

--Stream patches on production point initial sync
--prepend level information before everything else, so that the levelup is executed before the storage capacities are handled
--ATTENTION: Other mods that specifically affect this sync stream need to execute their read and write exactly in order. If not, desync will occur.
ProductionPoint.readStream = Utils.prependedFunction(ProductionPoint.readStream, UpgradableFactories.prodpointReadStream)
ProductionPoint.writeStream = Utils.prependedFunction(ProductionPoint.writeStream, UpgradableFactories.prodpointWriteStream)

--Other patches
PlaceableProductionPoint.onFinalizePlacement = Utils.appendedFunction(PlaceableProductionPoint.onFinalizePlacement, UpgradableFactories.onFinalizePlacement)
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, UpgradableFactories.saveToXML)
ProductionPoint.setOwnerFarmId = Utils.appendedFunction(ProductionPoint.setOwnerFarmId, UpgradableFactories.setOwnerFarmId)
