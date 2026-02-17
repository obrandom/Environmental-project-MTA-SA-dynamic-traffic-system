-- =============================================================================
-- PED REACTIONS - Server Side (DTRAFFIC STYLE)
-- Handles NPC reactions to damage, gunshots, and combat
-- Based on dtraffic/server.lua logic
-- =============================================================================

local DEBUG = false

local function debugLog(msg)
    if DEBUG then
        outputDebugString("[PedReact] " .. msg)
    end
end

-- =============================================================================
-- CONFIGURATION
-- =============================================================================

-- Weapon sets (SIMPLIFIED - only pistols now)
local PISTOL_WEAPON = 22  -- Colt 45 pistol only

-- Weapon sets for armed NPC types
local weaponsF = {22, 23}         -- Police: Colt 45, Silenced Pistol
local weaponsO = {22}             -- Gangsters: Colt 45

-- Default stats
local DEFAULT_COURAGE = 8
local PANIC_DURATION = 31 -- ticks

-- Vehicle reaction config
local VEHICLE_FLEE_DURATION = 8000 -- 8 seconds
local VEHICLE_SPEED_BOOST = 1.8 -- 80% faster
local VEHICLE_COOLDOWN = 5000 -- 5 seconds between reactions

-- Tracking tables
local vehicle_cooldowns = {}

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

local function percent(percentValue)
    local number = math.random(0, 200) / 2
    return number <= percentValue and 1 or 0
end

-- Check if ped is a traffic NPC
local function isTrafficNPC(ped)
    if not isElement(ped) then return false end
    if getElementType(ped) ~= "ped" then return false end
    return getElementData(ped, "npc_hlc") == true
end

-- Check if ped is traffic NPC in vehicle
local function isTrafficNPCInVehicle(ped)
    if not isTrafficNPC(ped) then return false end
    return isPedInVehicle(ped)
end

-- Save original npc_hlc state and disable it
local function disableNPCHLC(npc)
    if not isElement(npc) then return end
    
    -- Save original state
    local originalHLC = getElementData(npc, "npc_hlc")
    if originalHLC then
        setElementData(npc, "Onpc_hlc", originalHLC, false)
        removeElementData(npc, "npc_hlc")
        debugLog("Disabled npc_hlc for ped")
    end
end

-- Restore npc_hlc state and re-enable HLC system
local function restoreNPCHLC(npc)
    if not isElement(npc) then return end
    
    local originalHLC = getElementData(npc, "Onpc_hlc")
    if originalHLC then
        -- Clear the saved state
        removeElementData(npc, "Onpc_hlc")
        
        -- Try to use enableHLCForNPC to properly re-register the NPC
        if enableHLCForNPC then
            -- Re-enable with default settings
            local success = enableHLCForNPC(npc, "run", 1, 40/180)
            if success then
                debugLog("Restored HLC for ped via enableHLCForNPC")
            else
                -- Fallback: just set the element data
                setElementData(npc, "npc_hlc", true)
                debugLog("Restored npc_hlc element data (fallback)")
            end
        else
            -- No enableHLCForNPC function, just restore element data
            setElementData(npc, "npc_hlc", true)
            debugLog("Restored npc_hlc element data")
        end
    end
end

-- Get weapon for NPC (SIMPLIFIED - only pistols now)
local function getWeaponForNPC(npc)
    if not isElement(npc) then return 0 end
    
    -- Check if NPC has custom weapon
    local weapon = getElementData(npc, "BotWeapon")
    if weapon and weapon > 0 then
        return weapon
    end
    
    -- All armed NPCs get pistol only (for performance)
    return PISTOL_WEAPON
end

-- =============================================================================
-- NPC DAMAGE HANDLER (Main entry point - Pedestrians only)
-- =============================================================================

function onNpcDamage(npc, attacker, weapon, bodypart)
    if not isElement(npc) or not isElement(attacker) then return end
    if getElementType(attacker) ~= "player" then return end
    if getElementType(npc) ~= "ped" then return end
    
    -- Skip NPCs in vehicles - they have different behavior
    if isPedInVehicle(npc) then return end
    
    debugLog("NPC damage! Weapon: " .. tostring(weapon))
    
    -- Initialize NPC data if not set
    if not getElementData(npc, "type") then
        local model = getElementModel(npc)
        setElementData(npc, "gender", "male", false)
        setElementData(npc, "type", "citizen", false)
        setElementData(npc, "team", "citizen", false)
        setElementData(npc, "BotWeapon", 0, false)
        setElementData(npc, "Pcourage", DEFAULT_COURAGE, false)
        
        -- Police models
        if model >= 280 and model <= 288 then
            setElementData(npc, "type", "police", false)
            setElementData(npc, "Pcourage", 100, false)
            local wpn = weaponsF[math.random(#weaponsF)]
            giveWeapon(npc, wpn, 99999, true)
            setElementData(npc, "BotWeapon", wpn, false)
        -- Gangster models
        elseif (model >= 102 and model <= 127) or (model >= 247 and model <= 248) then
            setElementData(npc, "type", "gangster", false)
            setElementData(npc, "Pcourage", 95, false)
            local wpn = weaponsO[math.random(#weaponsO)]
            giveWeapon(npc, wpn, 99999, true)
            setElementData(npc, "BotWeapon", wpn, false)
        end
    end
    
    -- Check courage - will NPC fight or flee?
    local courage = getElementData(npc, "Pcourage") or DEFAULT_COURAGE
    
    if percent(courage) > 0 then
        -- NPC will FIGHT
        makeNPCFight(npc, attacker)
    else
        -- NPC will FLEE
        makeNPCFlee(npc, attacker)
    end
end
addEvent("onNpcDamage", true)
addEventHandler("onNpcDamage", getRootElement(), onNpcDamage)

-- =============================================================================
-- PANIC HANDLER (NPC hears gunshots - Pedestrians only)
-- =============================================================================

function onNpcPanic(npc)
    if not isElement(npc) then return end
    if getElementType(npc) ~= "ped" then return end
    if getElementData(npc, "attacked") == true then return end
    if isPedInVehicle(npc) then return end -- Skip NPCs in vehicles
    
    -- SIMPLIFIED: Only 2% of NPCs fight back with pistol, rest flee
    -- This greatly reduces performance impact
    if percent(2) > 0 then
        makeNPCFight(npc, source)
    else
        makeNPCFlee(npc, source)
    end
end
addEvent("onNpcPanic", true)
addEventHandler("onNpcPanic", getRootElement(), onNpcPanic)

-- =============================================================================
-- FIGHT MODE (NPC chases and attacks player) - Pedestrians only
-- =============================================================================

function makeNPCFight(npc, attacker)
    if not isElement(npc) or not isElement(attacker) then return end
    if getElementType(npc) ~= "ped" then return end
    if getElementData(npc, "attacked") == true then return end
    
    debugLog("NPC entering FIGHT mode")
    
    -- Set high courage so they keep fighting
    setElementData(npc, "Pcourage", 155, false)
    
    -- CRITICAL: Disable HLC route system
    disableNPCHLC(npc)
    
    -- Mark as attacked
    setElementData(npc, "attacked", true, false)
    
    -- Clear any animation
    setPedAnimation(npc)
    
    -- Mark for slothbot-style hunting
    setElementData(npc, "slothbot", true)
    setElementData(npc, "AllowFire", true)
    setElementData(npc, "status", "hunting")
    setElementData(npc, "target", attacker)
    
    -- Give weapon
    local weapon = getWeaponForNPC(npc)
    if weapon > 0 then
        giveWeapon(npc, weapon, 99999, true)
    end
    
    -- Save combat start time for timeout
    setElementData(npc, "combat_start_time", getTickCount(), false)
    
    -- Tell client to stop walking and start hunting
    triggerClientEvent("stopNPCWalking", attacker, npc)
    triggerClientEvent("startNPCHunting", attacker, npc, attacker)
    
    -- Timer to check if fight should end
    setTimer(checkNPCFightStatus, 1155, 1, npc)
end

-- Check if NPC should stop fighting
local MAX_COMBAT_TIME = 15000 -- 15 seconds max combat time

function checkNPCFightStatus(npc)
    if not isElement(npc) then return end
    
    -- Check timeout first
    local startTime = getElementData(npc, "combat_start_time") or 0
    local elapsed = getTickCount() - startTime
    
    if elapsed >= MAX_COMBAT_TIME then
        debugLog("NPC combat timeout - stopping fight")
        stopNPCFight(npc)
        return
    end
    
    local target = getElementData(npc, "target")
    
    -- Stop fighting if target is gone or is a ped (not player)
    if not target or not isElement(target) or getElementType(target) == "ped" then
        stopNPCFight(npc)
        return
    end
    
    -- Check if target is too far (over 100m)
    local px, py, pz = getElementPosition(npc)
    local tx, ty, tz = getElementPosition(target)
    local dist = getDistanceBetweenPoints3D(px, py, pz, tx, ty, tz)
    
    if dist > 100 then
        debugLog("NPC target too far - stopping fight")
        stopNPCFight(npc)
        return
    end
    
    -- Continue checking
    setTimer(checkNPCFightStatus, 1155, 1, npc)
end

-- Stop NPC from fighting and return to normal
function stopNPCFight(npc)
    if not isElement(npc) then return end
    
    debugLog("NPC exiting FIGHT mode")
    
    -- Clear fight data
    removeElementData(npc, "lock")
    removeElementData(npc, "slothbot")
    removeElementData(npc, "AllowFire")
    removeElementData(npc, "target")
    removeElementData(npc, "status")
    setElementData(npc, "attacked", false, false)
    
    -- Tell client to stop hunting
    triggerClientEvent("stopNPCHunting", root, npc)
    
    -- Restore HLC
    restoreNPCHLC(npc)
    
    -- Take weapon away
    takeAllWeapons(npc)
end

-- =============================================================================
-- FLEE MODE (NPC runs away in panic) - Pedestrians only
-- =============================================================================

function makeNPCFlee(npc, attacker)
    if not isElement(npc) then return end
    if getElementType(npc) ~= "ped" then return end
    
    debugLog("NPC entering FLEE mode")
    
    -- Mark as attacked
    setElementData(npc, "attacked", true, false)
    
    -- Start panic counter
    setElementData(npc, "panic", PANIC_DURATION, false)
    
    -- Set courage to 0
    setElementData(npc, "Pcourage", 0, false)
    
    -- Tell client to start panic running
    if isElement(attacker) then
        triggerClientEvent("startNPCPanic", attacker, npc)
    end
    
    -- Timer to update panic
    setTimer(updateNPCPanic, 755, 1, npc)
end

-- Update panic state (OPTIMIZED)
function updateNPCPanic(npc)
    if not isElement(npc) then return end
    
    local panicLevel = getElementData(npc, "panic") or 0
    
    if panicLevel >= 1 then
        -- Still panicking - only notify nearby players instead of ALL players
        local nx, ny, nz = getElementPosition(npc)
        local nearbyPlayers = getElementsWithinRange(nx, ny, nz, 75, "player")
        
        for _, player in ipairs(nearbyPlayers) do
            triggerClientEvent("startNPCPanic", player, npc)
        end
        
        setElementData(npc, "panic", panicLevel - 1, false)
        setTimer(updateNPCPanic, 755, 1, npc)
    else
        -- Panic over
        setElementData(npc, "attacked", false, false)
    end
end

-- =============================================================================
-- VEHICLE NPC REACTION (Accelerate and flee) - NOT exit vehicle!
-- =============================================================================

-- Check if vehicle can react (cooldown)
local function canVehicleReact(ped)
    if not isElement(ped) then return false end
    
    local lastReaction = vehicle_cooldowns[ped]
    if lastReaction and (getTickCount() - lastReaction) < VEHICLE_COOLDOWN then
        return false
    end
    
    if getElementData(ped, "vehicle.fleeing") then
        return false
    end
    
    return true
end

-- Make vehicle accelerate and flee
local function makeVehicleFlee(ped)
    if not isElement(ped) then return end
    if getElementType(ped) ~= "ped" then return end
    if getElementData(ped, "vehicle.fleeing") then return end
    
    local vehicle = getPedOccupiedVehicle(ped)
    if not vehicle then return end
    
    debugLog("Vehicle NPC fleeing from gunshots!")
    
    -- Set fleeing state
    setElementData(ped, "vehicle.fleeing", true, false)
    vehicle_cooldowns[ped] = getTickCount()
    
    -- Get current speed and save it
    local currentSpeed = getElementData(ped, "npc_hlc:drive_speed") or 0.5
    setElementData(ped, "vehicle.original_speed", currentSpeed, false)
    
    -- Boost speed
    local boostedSpeed = currentSpeed * VEHICLE_SPEED_BOOST
    boostedSpeed = math.min(boostedSpeed, 1.2) -- Cap at 1.2
    
    setElementData(ped, "npc_hlc:drive_speed", boostedSpeed)
    debugLog("Vehicle speed boosted from " .. tostring(currentSpeed) .. " to " .. tostring(boostedSpeed))
    
    -- After flee duration, return to normal speed
    setTimer(function()
        if isElement(ped) and isElement(vehicle) then
            setElementData(ped, "vehicle.fleeing", nil, false)
            
            -- Restore original speed
            local originalSpeed = getElementData(ped, "vehicle.original_speed") or currentSpeed
            setElementData(ped, "npc_hlc:drive_speed", originalSpeed)
            setElementData(ped, "vehicle.original_speed", nil, false)
            
            debugLog("Vehicle NPC back to normal speed: " .. tostring(originalSpeed))
        end
    end, VEHICLE_FLEE_DURATION, 1)
end

-- Listen for gunshots near vehicles (OPTIMIZED)
addEventHandler("onPlayerWeaponFire", root, function(weapon, endX, endY, endZ, hitElement, startX, startY, startZ)
    local shooter = source
    if not isElement(shooter) then return end
    if getElementType(shooter) ~= "player" then return end
    
    local sx, sy, sz = getElementPosition(shooter)
    local reactedCount = 0
    local GUNSHOT_HEAR_RADIUS = 50
    
    -- OPTIMIZED: Only get peds within range instead of ALL peds
    local nearbyPeds = getElementsWithinRange(sx, sy, sz, GUNSHOT_HEAR_RADIUS, "ped")
    
    for _, ped in ipairs(nearbyPeds) do
        if isElement(ped) and isTrafficNPCInVehicle(ped) and canVehicleReact(ped) then
            makeVehicleFlee(ped)
            reactedCount = reactedCount + 1
        end
    end
    
    if reactedCount > 0 then
        debugLog(reactedCount .. " vehicle NPCs fleeing from gunshots")
    end
end)

-- =============================================================================
-- NPC DEATH
-- =============================================================================

function NPCsWasted(killer, weapon, bodypart)
    local npc = source
    if not isElement(npc) then return end
    
    -- Stop any hunting
    removeElementData(npc, "slothbot")
    removeElementData(npc, "target")
    removeElementData(npc, "status")
    
    debugLog("NPC killed")
end
addEvent("NPCserverWasted", true)
addEventHandler("NPCserverWasted", getRootElement(), NPCsWasted)

-- =============================================================================
-- CLEANUP
-- =============================================================================

addEventHandler("onElementDestroy", root, function()
    if getElementType(source) == "ped" then
        vehicle_cooldowns[source] = nil
    end
end)
