-- =================================================================
--      NPC TURN SIGNAL SYSTEM - Using Custom Coronas
--      Version 1.0 - Visual turn signal system with orange coronas
-- =================================================================

local CoronaManager = exports.custom_coronas

-- Global functions cache
local getElementMatrix = getElementMatrix
local getElementPosition = getElementPosition
local getElementModel = getElementModel
local getVehicleController = getVehicleController
local getVehicleDummyPosition = getVehicleDummyPosition
local getElementsByType = getElementsByType
local isElement = isElement
local isElementOnScreen = isElementOnScreen
local getElementData = getElementData
local getTickCount = getTickCount
local pairs = pairs
local ipairs = ipairs

-- Turn signal system settings
local CONFIG = {
    turnSignalColor = {255, 165, 0},  -- Orange
    turnSignalAlpha = 140,
    turnSignalSize = 0.35,
    blinkInterval = 450,              -- ms between blinks
    renderDistance = 150,             -- Max render distance
    npcTurnSignalChance = 0.95,       -- 95% of NPCs use turn signals
}

-- Caches
local npcTurnSignalCache = {}        -- Cache of coronas per vehicle
local npcTurnSignalEnabled = {}      -- If NPC uses turn signals (95% chance)
local blinkState = {}                -- Blink state per vehicle

-- Vehicle cache to avoid getElementsByType every frame
local vehicleCache = {}
local vehicleCacheTime = 0
local VEHICLE_CACHE_INTERVAL = 200   -- Update cache every 200ms

-- Bicycle IDs (do not use turn signals)
local bicycleIDs = {[481] = true, [509] = true, [510] = true}

-- Function to calculate position from matrix
local function getPosFromMatrix(m, offX, offY, offZ)
    local x = offX * m[1][1] + offY * m[2][1] + offZ * m[3][1] + m[4][1]
    local y = offX * m[1][2] + offY * m[2][2] + offZ * m[3][2] + m[4][2]
    local z = offX * m[1][3] + offY * m[2][3] + offZ * m[3][3] + m[4][3]
    return x, y, z
end

-- Check if it's an NPC vehicle (not player's)
local function isNPCVehicle(veh, model)
    if bicycleIDs[model] then return false end  -- Bicycles do not use turn signals
    local driver = getVehicleController(veh)
    if driver and isElement(driver) then
        return getElementType(driver) ~= "player"
    end
    return false
end

-- Initialize cache for an NPC vehicle
local function initNPCTurnSignalCache(veh)
    if npcTurnSignalCache[veh] then return end
    
    -- Determine if this NPC will use turn signals (95% chance)
    if npcTurnSignalEnabled[veh] == nil then
        npcTurnSignalEnabled[veh] = math.random() < CONFIG.npcTurnSignalChance
    end
    
    if not npcTurnSignalEnabled[veh] then return end
    
    npcTurnSignalCache[veh] = {
        coronas = {},
        dummy = {}
    }
    
    -- Get light dummy positions
    local fx, fy, fz = getVehicleDummyPosition(veh, "light_front_main")
    local rx, ry, rz = getVehicleDummyPosition(veh, "light_rear_main")
    
    if fx then npcTurnSignalCache[veh].dummy["front"] = {fx, fy, fz} end
    if rx then npcTurnSignalCache[veh].dummy["rear"] = {rx, ry, rz} end
    
    blinkState[veh] = {
        on = false,
        lastBlink = 0
    }
end

-- Clear cache for a vehicle
local function cleanupNPCTurnSignal(veh)
    if npcTurnSignalCache[veh] then
        for key, corona in pairs(npcTurnSignalCache[veh].coronas) do
            if isElement(corona) then
                CoronaManager:destroyCorona(corona)
            end
        end
        npcTurnSignalCache[veh] = nil
    end
    blinkState[veh] = nil
    npcTurnSignalEnabled[veh] = nil
end

-- Create or update turn signal corona
local function updateTurnSignalCorona(veh, key, x, y, z, show)
    if not npcTurnSignalCache[veh] then return end
    
    local coronas = npcTurnSignalCache[veh].coronas
    local r, g, b = unpack(CONFIG.turnSignalColor)
    
    if show then
        if not coronas[key] or not isElement(coronas[key]) then
            coronas[key] = CoronaManager:createCorona(x, y, z, CONFIG.turnSignalSize, r, g, b, CONFIG.turnSignalAlpha)
        else
            CoronaManager:setCoronaPosition(coronas[key], x, y, z)
        end
    else
        if coronas[key] and isElement(coronas[key]) then
            CoronaManager:destroyCorona(coronas[key])
            coronas[key] = nil
        end
    end
end

-- Process turn signals for a specific vehicle
local function processVehicleTurnSignals(veh, now)
    local cache = npcTurnSignalCache[veh]
    if not cache then return end
    
    -- Read turn signal state (set by server via elementData)
    local turnLeft = getElementData(veh, "turn_left")
    local turnRight = getElementData(veh, "turn_right")
    local emergencyLight = getElementData(veh, "emergency_light")
    
    -- Emergency light (hazard) = both sides blink together
    if emergencyLight then
        turnLeft = true
        turnRight = true
    end
    
    if turnLeft or turnRight then
        -- Update blink
        if not blinkState[veh] then
            blinkState[veh] = {on = false, lastBlink = 0}
        end
        
        if now - blinkState[veh].lastBlink >= CONFIG.blinkInterval then
            blinkState[veh].on = not blinkState[veh].on
            blinkState[veh].lastBlink = now
        end
        
        local showCorona = blinkState[veh].on
        local matrix = getElementMatrix(veh)
        
        local fDummy = cache.dummy["front"]
        local rDummy = cache.dummy["rear"]
        
        if showCorona then
            -- Hazard mode: show both sides
            if emergencyLight or (turnLeft and turnRight) then
                -- Both sides ON
                if fDummy then
                    local lxL, lyL, lzL = getPosFromMatrix(matrix, fDummy[1] + 0.15, fDummy[2], fDummy[3])
                    local lxR, lyR, lzR = getPosFromMatrix(matrix, -fDummy[1] - 0.15, fDummy[2], fDummy[3])
                    updateTurnSignalCorona(veh, "front_left", lxL, lyL, lzL, true)
                    updateTurnSignalCorona(veh, "front_right", lxR, lyR, lzR, true)
                end
                if rDummy then
                    local lxL, lyL, lzL = getPosFromMatrix(matrix, rDummy[1] + 0.15, rDummy[2], rDummy[3])
                    local lxR, lyR, lzR = getPosFromMatrix(matrix, -rDummy[1] - 0.15, rDummy[2], rDummy[3])
                    updateTurnSignalCorona(veh, "rear_left", lxL, lyL, lzL, true)
                    updateTurnSignalCorona(veh, "rear_right", lxR, lyR, lzR, true)
                end
            else
                -- Left Signal only
                if turnLeft then
                    if fDummy then
                        local lx, ly, lz = getPosFromMatrix(matrix, fDummy[1] + 0.15, fDummy[2], fDummy[3])
                        updateTurnSignalCorona(veh, "front_left", lx, ly, lz, true)
                    end
                    if rDummy then
                        local lx, ly, lz = getPosFromMatrix(matrix, rDummy[1] + 0.15, rDummy[2], rDummy[3])
                        updateTurnSignalCorona(veh, "rear_left", lx, ly, lz, true)
                    end
                    updateTurnSignalCorona(veh, "front_right", 0, 0, 0, false)
                    updateTurnSignalCorona(veh, "rear_right", 0, 0, 0, false)
                end
                
                -- Right Signal only
                if turnRight then
                    if fDummy then
                        local lx, ly, lz = getPosFromMatrix(matrix, -fDummy[1] - 0.15, fDummy[2], fDummy[3])
                        updateTurnSignalCorona(veh, "front_right", lx, ly, lz, true)
                    end
                    if rDummy then
                        local lx, ly, lz = getPosFromMatrix(matrix, -rDummy[1] - 0.15, rDummy[2], rDummy[3])
                        updateTurnSignalCorona(veh, "rear_right", lx, ly, lz, true)
                    end
                    updateTurnSignalCorona(veh, "front_left", 0, 0, 0, false)
                    updateTurnSignalCorona(veh, "rear_left", 0, 0, 0, false)
                end
            end
        else
            -- Blink off - clear all coronas
            updateTurnSignalCorona(veh, "front_left", 0, 0, 0, false)
            updateTurnSignalCorona(veh, "rear_left", 0, 0, 0, false)
            updateTurnSignalCorona(veh, "front_right", 0, 0, 0, false)
            updateTurnSignalCorona(veh, "rear_right", 0, 0, 0, false)
        end
    else
        -- No active signal - clear coronas if they exist
        if cache.coronas then
            for key, corona in pairs(cache.coronas) do
                if isElement(corona) then
                    CoronaManager:destroyCorona(corona)
                end
            end
            cache.coronas = {}
        end
    end
end

-- Update NPC vehicle turn signals
local function updateNPCTurnSignals()
    local cx, cy, cz = getCameraMatrix()
    local now = getTickCount()
    
    -- Update vehicle cache periodically (not every frame)
    if now - vehicleCacheTime > VEHICLE_CACHE_INTERVAL then
        vehicleCache = getElementsByType("vehicle", root, true)
        vehicleCacheTime = now
    end
    
    for _, veh in ipairs(vehicleCache) do
        if isElement(veh) then  -- Vehicle might have been destroyed
            local model = getElementModel(veh)
            
            -- Only process NPC vehicles (not bicycles)
            if isNPCVehicle(veh, model) then
                local vx, vy, vz = getElementPosition(veh)
                local distSq = (vx - cx)^2 + (vy - cy)^2 + (vz - cz)^2
                
                if distSq < (CONFIG.renderDistance * CONFIG.renderDistance) and isElementOnScreen(veh) then
                    -- Initialize cache if necessary
                    if not npcTurnSignalCache[veh] then
                        initNPCTurnSignalCache(veh)
                    end
                    
                    -- If NPC uses turn signals and has cache, process
                    if npcTurnSignalEnabled[veh] and npcTurnSignalCache[veh] then
                        processVehicleTurnSignals(veh, now)
                    end
                else
                    -- Out of range - temporarily clear coronas
                    if npcTurnSignalCache[veh] and npcTurnSignalCache[veh].coronas then
                        for key, corona in pairs(npcTurnSignalCache[veh].coronas) do
                            if isElement(corona) then
                                CoronaManager:destroyCorona(corona)
                            end
                        end
                        npcTurnSignalCache[veh].coronas = {}
                    end
                end
            end
        end
    end
end

-- Cleanup when vehicle is destroyed or streamed out
addEventHandler("onClientElementDestroy", root, function()
    if getElementType(source) == "vehicle" then
        cleanupNPCTurnSignal(source)
    end
end)

addEventHandler("onClientElementStreamOut", root, function()
    if getElementType(source) == "vehicle" then
        cleanupNPCTurnSignal(source)
    end
end)

-- Start system
addEventHandler("onClientResourceStart", resourceRoot, function()
    setTimer(function()
        addEventHandler("onClientPreRender", root, updateNPCTurnSignals)
    end, 500, 1)
end)

-- Cleanup on resource stop
addEventHandler("onClientResourceStop", resourceRoot, function()
    for veh, _ in pairs(npcTurnSignalCache) do
        cleanupNPCTurnSignal(veh)
    end
end)

-- =============================================================================
-- DRIVER ARM-OUT-WINDOW ANIMATION SYSTEM (OPTIMIZED: event-driven)
-- Uses onClientElementDataChange instead of polling every 1s
-- =============================================================================
local processedDrivers = {}

local function applyArmAnimation(ped)
	if processedDrivers[ped] then return end
	
	local vehicle = getPedOccupiedVehicle(ped)
	if not vehicle or not isElement(vehicle) then return end
	
	-- Apply animation to driver
	setPedAnimation(ped, "CAR", "Tap_hand", -1, true, false, false, false)
	
	-- Hide left front window component
	local components = getVehicleComponents(vehicle)
	if components then
		for compName, _ in pairs(components) do
			local compLower = string.lower(compName)
			if string.find(compLower, "window") and string.find(compLower, "lf") then
				setVehicleComponentVisible(vehicle, compName, false)
			end
		end
	end
	
	processedDrivers[ped] = true
end

-- React when the data is set (instead of polling)
addEventHandler("onClientElementDataChange", root, function(key, oldVal, newVal)
	if key == "npc.armOutWindow" and newVal and getElementType(source) == "ped" then
		applyArmAnimation(source)
	end
end)

-- Also apply when ped streams in (data may already be set)
addEventHandler("onClientElementStreamIn", root, function()
	if getElementType(source) == "ped" and getElementData(source, "npc.armOutWindow") then
		applyArmAnimation(source)
	end
end)

-- Cleanup when ped is destroyed
addEventHandler("onClientElementDestroy", root, function()
	if getElementType(source) == "ped" then
		processedDrivers[source] = nil
	end
end)
