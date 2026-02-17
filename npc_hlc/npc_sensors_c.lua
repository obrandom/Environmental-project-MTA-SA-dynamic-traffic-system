-- npc_sensors_c.lua (CLIENT-SIDE) - OPTIMIZED v6.0
-- PERF: Delta-based sync — only sends sensor data when it changes significantly
-- FIX: Correctly detects player vehicles for braking to work

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local BASE_SCAN_INTERVAL = 50
local MAX_SCAN_INTERVAL = 150
local NPCS_PER_CHUNK = 15
local MIN_RANGE = 10.0
local MAX_RANGE = 60.0
local SPEED_FACTOR = 4.0

local CULL_DISTANCE = 150.0
local LOD_DISTANCE = 80.0
local CACHE_DURATION_MS = 150
local SLOW_SPEED_THRESHOLD = 0.05

-- Delta sync thresholds (only sync when data changes significantly)
local SYNC_DIST_THRESHOLD = 2.0    -- Sync if front dist changed by >2m
local SYNC_MIN_INTERVAL = 100      -- Minimum ms between syncs per NPC
local last_synced_data = {}         -- { [ped] = { dist, element, time } }

local ENABLE_DEBUG_SYNC = false
local LOCAL_DEBUG = false

-- =============================================================================
-- STATE
-- =============================================================================
local perf_stats = {
    npcs_processed = 0,
    raycasts_performed = 0,
    cache_hits = 0,
    last_scan_time = 0,
    adaptive_interval = BASE_SCAN_INTERVAL
}

local npc_list = {}
local npc_index = 1
local last_list_update = 0
local LIST_UPDATE_INTERVAL = 500

local raycast_cache = {}
local debug_data_cache = {}

local vehicle_cache = {}
local vehicle_cache_time = 0
local VEHICLE_CACHE_INTERVAL = 200

-- =============================================================================
-- COMMANDS
-- =============================================================================
function toggleLocalDebug()
    LOCAL_DEBUG = not LOCAL_DEBUG
    ENABLE_DEBUG_SYNC = LOCAL_DEBUG
    
    if not LOCAL_DEBUG then
        for ped, _ in pairs(debug_data_cache) do
            if isElement(ped) then
                setElementData(ped, "debug.sensor", nil, false)
            end
        end
        debug_data_cache = {}
    end
end
addCommandHandler("debugsensors", toggleLocalDebug)

addCommandHandler("sensorstats", function()
    -- Stats available via debug mode only
end)

-- =============================================================================
-- HELPERS
-- =============================================================================
local function getElementSpeed(element)
    if not isElement(element) then return 0 end
    local vx, vy, vz = getElementVelocity(element)
    return math.sqrt(vx*vx + vy*vy + vz*vz)
end

-- FIX: New function to get the actual vehicle of the detected element
local function getActualVehicle(element)
    if not isElement(element) then return nil end
    
    local elType = getElementType(element)
    
    -- If already a vehicle, return directly
    if elType == "vehicle" then
        return element
    end
    
    -- If it's a ped/player, get the vehicle they are occupying
    if elType == "ped" or elType == "player" then
        local vehicle = getPedOccupiedVehicle(element)
        if vehicle then
            return vehicle
        end
    end
    
    -- If not in a vehicle, return the element itself
    return element
end

local cachedCamPos = {x = 0, y = 0, z = 0}
local lastCamUpdate = 0

local function updateCameraCache()
    local now = getTickCount()
    if now - lastCamUpdate > 200 then
        cachedCamPos.x, cachedCamPos.y, cachedCamPos.z = getCameraMatrix()
        lastCamUpdate = now
    end
end

local function getDistanceToCamera(x, y, z)
    local dx = x - cachedCamPos.x
    local dy = y - cachedCamPos.y
    local dz = z - cachedCamPos.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- =============================================================================
-- RAYCAST
-- =============================================================================
local function castSensorRay(startX, startY, startZ, angle, dirX, dirY, range, ignoreVehicle)
    perf_stats.raycasts_performed = perf_stats.raycasts_performed + 1
    
    local ca, sa = math.cos(angle), math.sin(angle)
    local rayX = dirX * ca - dirY * sa
    local rayY = dirX * sa + dirY * ca
    
    local endX = startX + rayX * range
    local endY = startY + rayY * range
    local endZ = startZ
    
    local hit, hitX, hitY, hitZ, hitElement = processLineOfSight(
        startX, startY, startZ,
        endX, endY, endZ,
        true, true, true, true, false, false, false, false, ignoreVehicle
    )
    
    if hit then
        local dist = math.sqrt((hitX-startX)^2 + (hitY-startY)^2 + (hitZ-startZ)^2)
        return true, dist, hitElement, hitX, hitY, hitZ, rayX, rayY
    end
    
    return false, range, nil, endX, endY, endZ, rayX, rayY
end

-- =============================================================================
-- VEHICLE CACHE
-- =============================================================================
local function updateVehicleCache()
    local now = getTickCount()
    if now - vehicle_cache_time < VEHICLE_CACHE_INTERVAL then return end
    vehicle_cache_time = now
    
    vehicle_cache = {}
    local cx, cy, cz = cachedCamPos.x, cachedCamPos.y, cachedCamPos.z
    
    for _, veh in ipairs(getElementsByType("vehicle", root, true)) do
        local vx, vy, vz = getElementPosition(veh)
        local dx, dy = vx - cx, vy - cy
        local distSq = dx*dx + dy*dy
        
        if distSq < 10000 then
            vehicle_cache[#vehicle_cache + 1] = {
                element = veh,
                x = vx, y = vy, z = vz
            }
        end
    end
end

local function checkLateralProximityOptimized(x, y, z, rightX, rightY, range, excludeVeh)
    local leftThreat, rightThreat = nil, nil
    
    for i = 1, #vehicle_cache do
        local veh = vehicle_cache[i]
        if veh.element ~= excludeVeh then
            if math.abs(veh.z - z) < 3.0 then
                local dx, dy = veh.x - x, veh.y - y
                local totalDist = math.sqrt(dx*dx + dy*dy)
                
                if totalDist < range + 3 then
                    local sideProj = dx * rightX + dy * rightY
                    local fwdProj = dx * (-rightY) + dy * rightX
                    
                    if math.abs(fwdProj) < 5.0 then
                        local sideDist = math.abs(sideProj)
                        if sideDist < range then
                            if sideProj < 0 and (not leftThreat or sideDist < leftThreat.dist) then
                                leftThreat = { dist = sideDist, element = veh.element }
                            elseif sideProj > 0 and (not rightThreat or sideDist < rightThreat.dist) then
                                rightThreat = { dist = sideDist, element = veh.element }
                            end
                        end
                    end
                end
            end
        end
    end
    
    return leftThreat, rightThreat
end

-- =============================================================================
-- NPC LIST
-- =============================================================================
local function updateNPCList()
    local now = getTickCount()
    if now - last_list_update < LIST_UPDATE_INTERVAL then return end
    last_list_update = now
    
    npc_list = {}
    local peds = getElementsByType("ped", root, true)
    
    for _, ped in ipairs(peds) do
        local vehicle = getPedOccupiedVehicle(ped)
        if vehicle and getElementData(ped, "npc_hlc") then
            npc_list[#npc_list + 1] = ped
        end
    end
    
    if npc_index > #npc_list then
        npc_index = 1
    end
    
    local npc_count = #npc_list
    if npc_count > 50 then
        perf_stats.adaptive_interval = MAX_SCAN_INTERVAL
    elseif npc_count > 30 then
        perf_stats.adaptive_interval = 100
    else
        perf_stats.adaptive_interval = BASE_SCAN_INTERVAL
    end
end

-- =============================================================================
-- MAIN SENSOR PROCESSING - FIX: PLAYER VEHICLE DETECTION
-- =============================================================================
local function processNPCSensor(ped)
    local now = getTickCount()
    local vehicle = getPedOccupiedVehicle(ped)
    if not vehicle or not isElement(vehicle) then return end
    
    local x, y, z = getElementPosition(vehicle)
    local distToCam = getDistanceToCamera(x, y, z)
    
    if distToCam > CULL_DISTANCE then 
        return 
    end
    
    local mySpeed = getElementSpeed(vehicle)
    
    local useCache = false
    if not LOCAL_DEBUG then
        local cached = raycast_cache[ped]
        if cached and mySpeed < SLOW_SPEED_THRESHOLD then
            if now - cached.time < CACHE_DURATION_MS then
                useCache = true
                perf_stats.cache_hits = perf_stats.cache_hits + 1
                return
            end
        end
    end
    
    local isLOD = distToCam > LOD_DISTANCE
    
    local _, _, rz = getElementRotation(vehicle)
    local rad = math.rad(rz)
    
    local range = math.min(MAX_RANGE, math.max(MIN_RANGE, mySpeed * SPEED_FACTOR))
    
    local dirX, dirY = -math.sin(rad), math.cos(rad)
    local rightX, rightY = math.cos(rad), math.sin(rad)
    
    local sensorZ = z + 0.1
    local sensorX = x + dirX * 2.2
    local sensorY = y + dirY * 2.2
    
    local sensorData = {}
    local rayResults = {}
    local closestFront = nil
    local closestFrontDist = range + 10
    
    -- FRONT RAYS
    local frontAngles = (isLOD and not LOCAL_DEBUG) and {0, -0.25} or {0, -0.2, 0.2}
    for _, angle in ipairs(frontAngles) do
        local hit, dist, hitEl, hx, hy, hz, rx, ry = castSensorRay(
            sensorX, sensorY, sensorZ, angle, dirX, dirY, range, vehicle
        )
        
        if LOCAL_DEBUG then
            rayResults[#rayResults + 1] = {
                angle = angle,
                hit = hit,
                dist = dist,
                endX = hx, endY = hy, endZ = hz,
                rayX = rx, rayY = ry,
                zone = "front"
            }
        end
        
        if hit and hitEl and dist < closestFrontDist then
            local elType = getElementType(hitEl)
            if elType == "vehicle" or elType == "ped" or elType == "player" then
                closestFrontDist = dist
                
                -- FIX: If hit a ped/player, get their vehicle
                local actualVehicle = getActualVehicle(hitEl)
                
                closestFront = {
                    dist = dist,
                    isPed = (elType == "ped" or elType == "player"),
                    element = actualVehicle,  -- ← Now always sends the VEHICLE
                    originalElement = hitEl   -- Keeps original reference for debug
                }
            end
        end
    end
    
    -- DIAGONAL RAYS
    if not isLOD or LOCAL_DEBUG then
        local diagAngles = {-0.7, 0.7}
        for _, angle in ipairs(diagAngles) do
            local hit, dist, hitEl, hx, hy, hz, rx, ry = castSensorRay(
                sensorX, sensorY, sensorZ, angle, dirX, dirY, 18, vehicle
            )
            
            local zone = angle < 0 and "front_left" or "front_right"
            
            if LOCAL_DEBUG then
                rayResults[#rayResults + 1] = {
                    angle = angle,
                    hit = hit,
                    dist = dist,
                    endX = hx, endY = hy, endZ = hz,
                    rayX = rx, rayY = ry,
                    zone = zone
                }
            end
            
            if hit and hitEl then
                local elType = getElementType(hitEl)
                if elType == "vehicle" or elType == "ped" or elType == "player" then
                    -- FIX: Also correct here
                    local actualVehicle = getActualVehicle(hitEl)
                    sensorData[zone] = { dist = dist, element = actualVehicle }
                end
            end
        end
    end
    
    -- LATERAL PROXIMITY
    if not isLOD or LOCAL_DEBUG then
        local leftThreat, rightThreat = checkLateralProximityOptimized(x, y, z, rightX, rightY, 6.0, vehicle)
        sensorData.side_left = leftThreat
        sensorData.side_right = rightThreat
    end
    
    sensorData.front = closestFront
    
    -- OPTIMIZED: Always set local data (for client-side reading)
    setElementData(ped, "npc.sensors", sensorData, false)
    
    -- DELTA SYNC: Only sync to server when data changes significantly
    local lastSync = last_synced_data[ped]
    local needsSync = false
    
    if not lastSync then
        needsSync = true
    elseif (now - lastSync.time) < SYNC_MIN_INTERVAL then
        needsSync = false  -- Rate-limit
    else
        local newDist = closestFront and closestFront.dist or 999
        local oldDist = lastSync.dist or 999
        local newEl = closestFront and closestFront.element or nil
        local oldEl = lastSync.element or nil
        
        -- Sync if target changed or distance shifted significantly
        if newEl ~= oldEl then
            needsSync = true
        elseif math.abs(newDist - oldDist) > SYNC_DIST_THRESHOLD then
            needsSync = true
        end
    end
    
    if needsSync then
        setElementData(ped, "npc.sensors", sensorData, true)
        last_synced_data[ped] = {
            dist = closestFront and closestFront.dist or 999,
            element = closestFront and closestFront.element or nil,
            time = now
        }
    end
    
    if not LOCAL_DEBUG then
        raycast_cache[ped] = {
            time = now,
            speed = mySpeed
        }
    end
    
    -- Debug data (local only)
    if LOCAL_DEBUG and ENABLE_DEBUG_SYNC then
        local debugData = {
            rays = rayResults,
            lateral = {
                left = sensorData.side_left and sensorData.side_left.dist or nil,
                right = sensorData.side_right and sensorData.side_right.dist or nil
            },
            origin = {x = sensorX, y = sensorY, z = sensorZ},
            range = range,
            speed = math.floor(mySpeed * 180),
            target = closestFront and closestFront.originalElement or nil,  -- Show original element in debug
            targetDist = closestFront and closestFront.dist or nil
        }
        
        debug_data_cache[ped] = debugData
        setElementData(ped, "debug.sensor", debugData, false)
    end
end

-- =============================================================================
-- MAIN SCAN
-- =============================================================================
local function scanNPCSensorsChunked()
    local now = getTickCount()
    perf_stats.last_scan_time = now
    
    if perf_stats.raycasts_performed > 10000 then
        perf_stats.raycasts_performed = 0
        perf_stats.cache_hits = 0
        perf_stats.npcs_processed = 0
    end
    
    updateCameraCache()
    updateVehicleCache()
    updateNPCList()
    
    local npc_count = #npc_list
    if npc_count == 0 then return end
    
    local chunk_end = math.min(npc_index + NPCS_PER_CHUNK - 1, npc_count)
    
    for i = npc_index, chunk_end do
        local ped = npc_list[i]
        if isElement(ped) then
            processNPCSensor(ped)
            perf_stats.npcs_processed = perf_stats.npcs_processed + 1
        end
    end
    
    npc_index = chunk_end + 1
    if npc_index > npc_count then
        npc_index = 1
    end
end

-- =============================================================================
-- TIMER
-- =============================================================================
local sensor_timer = nil

local function restartSensorTimer()
    if sensor_timer and isTimer(sensor_timer) then
        killTimer(sensor_timer)
    end
    
    sensor_timer = setTimer(function()
        scanNPCSensorsChunked()
    end, perf_stats.adaptive_interval, 0)
end

restartSensorTimer()

setTimer(function()
    if not sensor_timer or not isTimer(sensor_timer) then
        restartSensorTimer()
    end
end, 1000, 0)

addEventHandler("onClientElementDestroy", root, function()
    if getElementType(source) == "ped" then
        raycast_cache[source] = nil
        debug_data_cache[source] = nil
        last_synced_data[source] = nil
    end
end)