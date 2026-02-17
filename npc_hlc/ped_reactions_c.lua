-- =============================================================================
-- PED REACTIONS - Client Side (DTRAFFIC STYLE)
-- Detects damage to peds and controls hunting/panic behavior
-- =============================================================================

-- =============================================================================
-- DAMAGE DETECTION
-- =============================================================================

function NPCDamage(attacker, weapon, bodypart, loss)
    local npc = source
    if not isElement(npc) then return end
    if getElementType(npc) ~= "ped" then return end
    
    -- Skip if already attacked or panicking
    if getElementData(npc, "attacked") == true then return end
    if getElementData(npc, "panic") and getElementData(npc, "panic") >= 1 then return end
    
    -- Handle vehicle collision (weapon 49)
    if weapon == 49 and isElement(attacker) then
        attacker = getVehicleOccupant(attacker)
    end
    
    -- Only trigger if local player is the attacker
    if isElement(attacker) and attacker == getLocalPlayer() then 
        triggerServerEvent("onNpcDamage", getLocalPlayer(), npc, attacker, weapon, bodypart)
        -- Trigger reaction audio for this NPC
        triggerEvent("onNpcReactionAudio", root, npc)
    end
end
addEventHandler("onClientPedDamage", getRootElement(), NPCDamage)

-- =============================================================================
-- GUNSHOT PANIC DETECTION (OPTIMIZED)
-- =============================================================================

-- Throttle: limit reactions per second to avoid spam
local lastPanicTrigger = 0
local PANIC_THROTTLE_MS = 200 -- max 5 reactions per second

function onClientPlayerWeaponFireHandler(weapon, ammo, ammoInClip, hitX, hitY, hitZ, hitElement)
    -- Only for guns (16-39)
    if weapon < 16 or weapon > 39 then return end
    
    local shooter = source
    if shooter ~= getLocalPlayer() then return end
    
    -- Throttle check
    local now = getTickCount()
    if now - lastPanicTrigger < PANIC_THROTTLE_MS then return end
    lastPanicTrigger = now
    
    local x, y, z = getElementPosition(shooter)
    local MAX_REACT_DISTANCE = 65 -- Max distance any ped reacts
    local MAX_REACTS_PER_SHOT = 5 -- Limit reactions per shot
    local reactCount = 0
    
    -- OPTIMIZED: Only get peds within max range instead of ALL peds
    local nearbyPeds = getElementsWithinRange(x, y, z, MAX_REACT_DISTANCE, "ped")
    
    for _, npc in ipairs(nearbyPeds) do
        if reactCount >= MAX_REACTS_PER_SHOT then break end
        
        if isElement(npc) then
            -- Skip if already attacked or in vehicle
            if getElementData(npc, "attacked") ~= true and not isPedInVehicle(npc) then
                local vx, vy, vz = getElementPosition(npc)
                local dist = getDistanceBetweenPoints3D(x, y, z, vx, vy, vz)
                
                -- Police react from 65m, citizens from 45m
                local model = getElementModel(npc)
                local maxDist = (model >= 280 and model <= 288) and 65 or 45
                
                if dist <= maxDist then
                    triggerServerEvent("onNpcPanic", shooter, npc)
                    -- Trigger reaction audio for this panicking NPC
                    triggerEvent("onNpcReactionAudio", root, npc)
                    reactCount = reactCount + 1
                end
            end
        end
    end
end
addEventHandler("onClientPlayerWeaponFire", root, onClientPlayerWeaponFireHandler)

-- =============================================================================
-- NPC BEHAVIOR CONTROL (Client-side movement)
-- =============================================================================

-- Stop NPC from walking (when entering combat mode)
function stopNPCWalking(npc)
    if not isElement(npc) then return end
    if getElementType(npc) ~= "ped" then return end
    
    setPedControlState(npc, "forwards", false)
    setPedControlState(npc, "backwards", false)
    setPedControlState(npc, "sprint", false)
    setPedControlState(npc, "walk", false)
end
addEvent("stopNPCWalking", true)
addEventHandler("stopNPCWalking", getRootElement(), stopNPCWalking)

-- Make NPC panic/run
function startNPCPanic(npc)
    if not isElement(npc) then return end
    if getElementType(npc) ~= "ped" then return end
    
    setPedControlState(npc, "forwards", true)
    setPedControlState(npc, "sprint", true)
    setPedControlState(npc, "walk", false)
end
addEvent("startNPCPanic", true)
addEventHandler("startNPCPanic", getRootElement(), startNPCPanic)

-- =============================================================================
-- HUNTING SYSTEM (NPC chases and shoots at player)
-- =============================================================================

local huntingNPCs = {}

function startNPCHunting(npc, target)
    if not isElement(npc) or not isElement(target) then return end
    if getElementType(npc) ~= "ped" then return end
    
    huntingNPCs[npc] = {
        target = target,
        lastShot = 0
    }
end
addEvent("startNPCHunting", true)
addEventHandler("startNPCHunting", getRootElement(), startNPCHunting)

function stopNPCHunting(npc)
    if not isElement(npc) then 
        huntingNPCs[npc] = nil
        return 
    end
    
    if huntingNPCs[npc] then
        -- Stop all controls safely
        if getElementType(npc) == "ped" then
            setPedControlState(npc, "forwards", false)
            setPedControlState(npc, "sprint", false)
            setPedControlState(npc, "fire", false)
            setPedControlState(npc, "aim_weapon", false)
        end
        huntingNPCs[npc] = nil
    end
end
addEvent("stopNPCHunting", true)
addEventHandler("stopNPCHunting", getRootElement(), stopNPCHunting)

-- Main hunting loop
function updateHuntingNPCs()
    local now = getTickCount()
    local toRemove = {}
    
    for npc, data in pairs(huntingNPCs) do
        -- Safety checks
        if not isElement(npc) then
            toRemove[npc] = true
        elseif getElementType(npc) ~= "ped" then
            toRemove[npc] = true
        elseif not isElement(data.target) then
            toRemove[npc] = true
        elseif getElementHealth(data.target) < 1 then
            -- Target dead, stop hunting
            toRemove[npc] = true
        else
            -- Get positions
            local px, py, pz = getElementPosition(npc)
            local tx, ty, tz = getElementPosition(data.target)
            
            -- Aim at target's body for shooting
            local aimX, aimY, aimZ = tx, ty, tz
            if getElementType(data.target) == "player" then
                aimX, aimY, aimZ = getPedBonePosition(data.target, 3) -- Spine
            end
            
            -- Calculate distance and angle to target
            local dx, dy = tx - px, ty - py
            local dist = getDistanceBetweenPoints3D(px, py, pz, tx, ty, tz)
            
            -- Calculate angle (MTA uses different rotation system)
            -- atan2(dx, dy) gives angle from north, but we need to convert to MTA rotation
            local angle = -math.deg(math.atan2(dx, dy))
            
            -- Set BOTH camera and ped rotation so they actually face and run toward target
            setPedCameraRotation(npc, angle)
            setPedRotation(npc, angle)
            
            -- If far, run toward target
            if dist > 8 then
                setPedControlState(npc, "forwards", true)
                setPedControlState(npc, "sprint", true)
                setPedControlState(npc, "fire", false)
                setPedControlState(npc, "aim_weapon", false)
            else
                -- Close enough, stop and shoot
                setPedControlState(npc, "forwards", false)
                setPedControlState(npc, "sprint", false)
                
                -- Aim and shoot
                setPedAimTarget(npc, aimX, aimY, aimZ)
                setPedControlState(npc, "aim_weapon", true)
                
                -- Toggle fire for continuous shooting
                if now - data.lastShot > 200 then
                    setPedControlState(npc, "fire", not getPedControlState(npc, "fire"))
                    data.lastShot = now
                end
            end
        end
    end
    
    -- Remove invalid NPCs outside of loop
    for npc, _ in pairs(toRemove) do
        if isElement(npc) and getElementType(npc) == "ped" then
            setPedControlState(npc, "forwards", false)
            setPedControlState(npc, "sprint", false)
            setPedControlState(npc, "fire", false)
            setPedControlState(npc, "aim_weapon", false)
        end
        huntingNPCs[npc] = nil
    end
end

-- Run hunting loop every 100ms (optimized from 50ms)
setTimer(updateHuntingNPCs, 100, 0)

-- =============================================================================
-- DEATH HANDLING
-- =============================================================================

function onWastedNPC(killer, weapon, bodypart)
    if not isElement(source) then return end
    if getElementType(source) ~= "ped" then return end
    
    -- Stop hunting this NPC
    if huntingNPCs[source] then
        huntingNPCs[source] = nil
    end
    
    if isElement(killer) and killer == getLocalPlayer() then
        triggerServerEvent("NPCserverWasted", source, killer, weapon, bodypart)
    end
end
addEventHandler("onClientPedWasted", getRootElement(), onWastedNPC)

-- Cleanup on element destroy
addEventHandler("onClientElementDestroy", root, function()
    if huntingNPCs[source] then
        huntingNPCs[source] = nil
    end
end)
