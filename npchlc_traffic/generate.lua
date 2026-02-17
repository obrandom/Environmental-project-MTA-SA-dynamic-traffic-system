--[[
    Traffic and Trailer Generation Script for MTASA
    Final Corrected Version: NPC spawn in the first right lane of its direction,
    avoiding conflicts with npc_hlc AI.
]]

trailer_connections = {} -- Table to track truck-trailer connections
local player_last_squares = {} -- Table to track last quadrant of each player

-- Declare traffic_density as global so f_density.lua can access it before initTrafficGenerator()
traffic_density = {peds = 0.0027, cars = 0.0027, boats = 0, planes = 0}

-- =============================================================================
-- ANTI-AFK SYSTEM: Detects idle players and limits NPC spawns
-- =============================================================================
local player_positions = {}  -- {player = {x, y, z, lastMoveTime}}
local AFK_THRESHOLD_MS = 8000   -- 8 seconds idle = AFK (was 15)
local MAX_NPCS_NEAR_AFK_PLAYER = 5  -- Limit of 5 NPCs near AFK player (was 10)
local AFK_CHECK_RADIUS_SQ = 40000   -- 200m² around AFK player (was 100m)

-- =============================================================================
-- SCALABILITY SYSTEM: Optimization for many players
-- =============================================================================
local SCALABILITY_CONFIG = {
    CLUSTER_RADIUS = 150,           -- Players within 150m are considered a cluster
    CLUSTER_RADIUS_SQ = 22500,      -- 150² to avoid sqrt
    MIN_DENSITY_MODIFIER = 0.15,    -- Minimum 15% density (with many players)
    PLAYERS_FOR_MIN_DENSITY = 500,  -- 500+ players = minimum density
    SHARED_NPC_RADIUS = 200,        -- NPCs are shared within 200m
}

-- GLOBAL LIMITS
local MAX_GLOBAL_NPCS = 2000      -- Server safety limit (~600 is healthy for most)
local SPAWN_RADIUS_ACTIVE = 8    -- 800m (Sufficient for streaming, fixes the 1000 NPCs issue)
local SPAWN_RADIUS_STATIC = 10   -- 1000m (Safe margin)

-- Player clusters table (updated every cycle)
local player_clusters = {}  -- {cluster_id = {players = {}, center_x, center_y, owner}}
local player_to_cluster = {} -- {player = cluster_id}
current_density_modifier = 1.0  -- Current density modifier (updated every cycle)

-- Function to check if player is AFK
local function isPlayerAFK(player)
    if not isElement(player) then return false end
    
    local px, py, pz = getElementPosition(player)
    local now = getTickCount()
    local key = tostring(player)
    
    if not player_positions[key] then
        player_positions[key] = {x = px, y = py, z = pz, lastMoveTime = now}
        return false
    end
    
    local data = player_positions[key]
    local dx, dy, dz = px - data.x, py - data.y, pz - data.z
    local distSq = dx*dx + dy*dy + dz*dz
    
    -- If moved more than 1 meter, update position (was 2m)
    if distSq > 1 then
        data.x, data.y, data.z = px, py, pz
        data.lastMoveTime = now
        return false
    end
    
    -- Check if idle for a long time
    return (now - data.lastMoveTime) > AFK_THRESHOLD_MS
end

-- Function to count and get NPCs near a player
local function getNPCsNearPlayer(player, onlyCount)
    if not isElement(player) then return onlyCount and 0 or {} end
    
    local px, py, pz = getElementPosition(player)
    local count = 0
    local npcs = {}
    
    for vehicle, _ in pairs(population.cars) do
        if isElement(vehicle) then
            local vx, vy, vz = getElementPosition(vehicle)
            local dx, dy, dz = px - vx, py - vy, pz - vz
            local distSq = dx*dx + dy*dy + dz*dz
            if distSq < AFK_CHECK_RADIUS_SQ then
                count = count + 1
                if not onlyCount then
                    npcs[#npcs + 1] = {vehicle = vehicle, distSq = distSq}
                end
            end
        end
    end
    
    return onlyCount and count or npcs
end

-- Function to remove excessive NPCs near AFK player
local function removeExcessNPCsNearAFKPlayer(player)
    if not isPlayerAFK(player) then return end
    
    local npcs = getNPCsNearPlayer(player, false)
    if #npcs <= MAX_NPCS_NEAR_AFK_PLAYER then return end
    
    -- Sort by distance (remove farthest first)
    table.sort(npcs, function(a, b) return a.distSq > b.distSq end)
    
    -- Remove excess NPCs
    local toRemove = #npcs - MAX_NPCS_NEAR_AFK_PLAYER
    for i = 1, toRemove do
        local vehicle = npcs[i].vehicle
        if isElement(vehicle) then
            local occupants = getVehicleOccupants(vehicle)
            if occupants then
                for seat, ped in pairs(occupants) do
                    if isElement(ped) and population.peds[ped] then
                        destroyElement(ped)
                    end
                end
            end
            if trailer_connections[vehicle] then
                local trailer = trailer_connections[vehicle]
                if isElement(trailer) then destroyElement(trailer) end
                trailer_connections[vehicle] = nil
            end
            destroyElement(vehicle)
        end
    end
end

-- Function to check if spawning is allowed near a player
local function canSpawnNearPlayer(player)
    if not isElement(player) then return true end
    
    -- If player is AFK, check limit AND remove excess
    if isPlayerAFK(player) then
        removeExcessNPCsNearAFKPlayer(player)  -- Remove excessive NPCs
        local nearbyCount = getNPCsNearPlayer(player, true)
        return nearbyCount < MAX_NPCS_NEAR_AFK_PLAYER
    end
    
    return true  -- Active player, spawn normally
end

-- =============================================================================
-- SCALABILITY SYSTEM: Optimization functions
-- =============================================================================

-- Calculates density modifier based on player count
function getDynamicDensityModifier()
    local player_count = 0
    for _ in pairs(players) do
        player_count = player_count + 1
    end
    
    -- Formula: 1.0 with few players, decreases to MIN_DENSITY_MODIFIER with many
    -- 0 players = 1.0, 500 players = 0.15
    local modifier = 1.0 - (player_count / SCALABILITY_CONFIG.PLAYERS_FOR_MIN_DENSITY)
    modifier = math.max(SCALABILITY_CONFIG.MIN_DENSITY_MODIFIER, modifier)
    
    return modifier, player_count
end

-- Updates player clusters (groups nearby players)
function updatePlayerClusters()
    player_clusters = {}
    player_to_cluster = {}
    
    local cluster_id = 0
    local processed = {}
    
    for player in pairs(players) do
        if isElement(player) and not processed[player] then
            cluster_id = cluster_id + 1
            local px, py, pz = getElementPosition(player)
            local dim = getElementDimension(player)
            
            -- Create new cluster
            player_clusters[cluster_id] = {
                players = {player},
                center_x = px,
                center_y = py,
                center_z = pz,
                dimension = dim,
                owner = player  -- First found player is the "owner"
            }
            player_to_cluster[player] = cluster_id
            processed[player] = true
            
            -- Find nearby players to add to cluster
            for other_player in pairs(players) do
                if isElement(other_player) and not processed[other_player] then
                    local ox, oy, oz = getElementPosition(other_player)
                    local odim = getElementDimension(other_player)
                    
                    -- Check if in same dimension and close
                    if odim == dim then
                        local dx, dy = ox - px, oy - py
                        local distSq = dx*dx + dy*dy
                        
                        if distSq < SCALABILITY_CONFIG.CLUSTER_RADIUS_SQ then
                            -- Add to existing cluster
                            table.insert(player_clusters[cluster_id].players, other_player)
                            player_to_cluster[other_player] = cluster_id
                            processed[other_player] = true
                        end
                    end
                end
            end
        end
    end
    
    return cluster_id  -- Returns number of clusters
end

-- Checks if this player is the "owner" of their cluster (responsible for spawning NPCs)
function isClusterOwner(player)
    local cluster_id = player_to_cluster[player]
    if not cluster_id then return true end  -- No cluster = owns self
    
    local cluster = player_clusters[cluster_id]
    if not cluster then return true end
    
    return cluster.owner == player
end

-- Gets cluster center for a player (for shared spawn)
function getClusterCenter(player)
    local cluster_id = player_to_cluster[player]
    if not cluster_id then 
        local px, py, pz = getElementPosition(player)
        return px, py, pz
    end
    
    local cluster = player_clusters[cluster_id]
    if not cluster then
        local px, py, pz = getElementPosition(player)
        return px, py, pz
    end
    
    return cluster.center_x, cluster.center_y, cluster.center_z
end
-- =============================================================================

-- Vehicle types by category (used for trailer and passenger spawning)
local VEHICLE_CATEGORIES = {
    HEAVY = {514, 515, 414, 455, 456, 578, 579, 600, 424, 573, 531, 408, 423, 588, 434, 443, 470, 524, 525},
    SPORTS = {402, 411, 415, 429, 451, 477, 494, 502, 503, 506, 541, 559, 560, 565, 587, 602, 603},
    MOTORCYCLE = {462, 463, 468, 471, 521, 522, 581, 586},
    BICYCLE = {509, 510, 481},  -- Bike, Mountain Bike, BMX
    EMERGENCY = {416, 407, 544, 596, 597, 598, 599}, -- Ambulance, Fire Truck, Fire LA, Police LS, Police SF, Police LV, Police Ranger
    NORMAL = {400, 401, 404, 405, 410, 412, 419, 421, 426, 436, 445, 458, 466, 467, 474, 475, 479, 480, 491, 492, 496, 500, 507, 516, 517, 518, 526, 527, 529, 533, 534, 535, 536, 540, 542, 545, 546, 547, 549, 550, 551, 554, 555, 558, 561, 562, 566, 567, 575, 576, 580, 582, 583, 585, 589, 596, 597, 598, 599, 604, 605}
}

-- Table to track emergency vehicles with active sirens
local emergency_vehicles = {}

function getVehicleCategory(model)
    for category, models in pairs(VEHICLE_CATEGORIES) do
        for _, vehicleModel in ipairs(models) do
            if vehicleModel == model then
                return category
            end
        end
    end
    return "NORMAL"
end

function initTrafficGenerator()
    -- Use game time for consistency with f_dynamic_density.lua
    local hour, min = getTime()
    
    -- Peak hours: 07:00-09:00 and 17:00-19:00 = 0.30%
    -- Low hours: 00:00-05:00 = 0.08%
    -- Default: 0.27%
    local density
    if (hour >= 7 and hour < 9) or (hour >= 17 and hour < 19) then
        density = 0.003  -- 0.30%
    elseif (hour >= 0 and hour < 5) then
        density = 0.0008  -- 0.08%
    else
        density = 0.0027  -- 0.27%
    end
    
    traffic_density = {peds = density, cars = density, boats = 0, planes = 0}

    population = {peds = {}, cars = {}, boats = {}, planes = {}}
    element_timers = {}

    players = {}
    for plnum, player in ipairs(getElementsByType("player")) do
        players[player] = true
    end
    addEventHandler("onPlayerJoin", root, addPlayerOnJoin)
    addEventHandler("onPlayerQuit", root, removePlayerOnQuit)

    square_subtable_count = {}

    setTimer(updateTraffic, 8000, 0)
    setTimer(removeFarTrafficElements, 15000, 0)
    setTimer(renewTrafficDynamic, 18000, 0)
    setTimer(forceReattachTrailers, 10000, 0)
    setTimer(garbageCollectSquares, 60000, 0) -- Run GC every 60s
end

function addPlayerOnJoin()
    players[source] = true
end

function removePlayerOnQuit()
    local player_key = tostring(source)
    players[source] = nil
    player_last_squares[player_key] = nil
end

function updateTraffic()
    server_coldata = getResourceFromName("server_coldata")
    npc_hlc = getResourceFromName("npc_hlc")

    colcheck = get("npchlc_traffic.check_collisions")
    colcheck = colcheck == "all" and root or colcheck == "local" and resourceRoot or nil

    updateSquarePopulations()
    generateTraffic()
end

function updateSquarePopulations()
    if square_population then
        for dim, square_dim in pairs(square_population) do
            for y, square_row in pairs(square_dim) do
                for x, square in pairs(square_row) do
                    square.count = {peds = 0, cars = 0, boats = 0, planes = 0}
                    square.list = {peds = {}, cars = {}, boats = {}, planes = {}}
                    square.gen_mode = "despawn"
                end
            end
        end
    end

    countPopulationInSquares("peds")
    countPopulationInSquares("cars")
    countPopulationInSquares("boats")
    countPopulationInSquares("planes")

    -- SCALABILITY: Update player clusters before loop
    local cluster_count = updatePlayerClusters()
    local density_modifier, player_count = getDynamicDensityModifier()
    
    for player, exists in pairs(players) do
        -- SCALABILITY: Only process if cluster owner (Shared NPCs)
        if isClusterOwner(player) then
            local px, py, pz = getElementPosition(player)
            local dim = getElementDimension(player)
            local current_x, current_y = math.floor(px/SQUARE_SIZE), math.floor(py/SQUARE_SIZE)
            
            local player_key = tostring(player)
            local last_square = player_last_squares[player_key]
            local moved_significantly = false
            
            if not last_square then
                moved_significantly = true
                player_last_squares[player_key] = {x = current_x, y = current_y, dim = dim}
            else
                local distance = math.sqrt((current_x - last_square.x)^2 + (current_y - last_square.y)^2)
                if distance > 2 or last_square.dim ~= dim then
                    moved_significantly = true
                    player_last_squares[player_key] = {x = current_x, y = current_y, dim = dim}
                end
            end

            -- CORRECTION: Reduce spawn radius to realistic values (800m - 1000m)
            local spawn_radius = moved_significantly and SPAWN_RADIUS_ACTIVE or SPAWN_RADIUS_STATIC
            
            -- ANTI-AFK: Check if spawning is allowed near this player
            local can_spawn = canSpawnNearPlayer(player)
            
            -- GLOBAL CAP CHECK BEFORE CREATING NEW SQUARES
            local total_npcs = 0
            if population.cars then for _ in pairs(population.cars) do total_npcs = total_npcs + 1 end end
            
            if total_npcs >= MAX_GLOBAL_NPCS then
                 can_spawn = false
            end
            
            for sy = current_y - spawn_radius, current_y + spawn_radius do 
                for sx = current_x - spawn_radius, current_x + spawn_radius do
                    local square = getPopulationSquare(sx, sy, dim)
                    if not square then
                        -- Only create new square if player is not AFK with many NPCs
                        if can_spawn then
                            square = createPopulationSquare(sx, sy, dim, "spawn")
                        end
                    else
                        -- If player AFK with many NPCs, mark for despawn instead of spawn
                        square.gen_mode = can_spawn and "spawn" or "despawn"
                        square.last_visit = getTickCount()
                    end
                end 
            end
            
            local despawn_radius = spawn_radius + 7
            for sy = current_y - despawn_radius, current_y + despawn_radius do 
                for sx = current_x - despawn_radius, current_x + despawn_radius do
                    local distance_from_player = math.sqrt((sx - current_x)^2 + (sy - current_y)^2)
                    if distance_from_player > spawn_radius then
                        local square = getPopulationSquare(sx, sy, dim)
                        if square then
                            square.gen_mode = "despawn"
                        end
                    end
                end 
            end
        end  -- end isClusterOwner
    end
    
    -- Store density_modifier for use in generateTraffic
    current_density_modifier = density_modifier

    if colcheck then call(server_coldata, "generateColData", colcheck) end
end

function removeFarTrafficElements()
    if not square_population then return end

    local safe_distance = SQUARE_SIZE * 12 -- 1200m (Safety margin above 1000m spawn)
    local safe_distance_sq = safe_distance * safe_distance  -- Use squared distance (avoids sqrt)
    local removed_count = 0
    
    -- OPTIMIZED: Pre-calculate player positions once
    local playerPositions = {}
    for player in pairs(players) do
        if isElement(player) then
            local px, py, pz = getElementPosition(player)
            playerPositions[#playerPositions + 1] = {px, py, pz}
        end
    end

    for vehicle, _ in pairs(population.cars) do
        if isElement(vehicle) then
            local vx, vy, vz = getElementPosition(vehicle)
            local should_remove = true
            
            -- Use pre-calculated positions
            for i = 1, #playerPositions do
                local pp = playerPositions[i]
                -- Squared distance (faster, avoids sqrt)
                local dx, dy, dz = pp[1] - vx, pp[2] - vy, pp[3] - vz
                local distSq = dx*dx + dy*dy + dz*dz
                
                if distSq < safe_distance_sq then
                    should_remove = false
                    break
                end
            end

            if should_remove then
                local occupants = getVehicleOccupants(vehicle)
                if not occupants then occupants = {} end                
                
                -- FIXED: Destroy peds BEFORE destroying vehicle
                for seat, ped in pairs(occupants) do
                    if isElement(ped) and population.peds[ped] then
                        destroyElement(ped)
                    end
                end
                
                if trailer_connections[vehicle] then
                    local trailer = trailer_connections[vehicle]
                    if isElement(trailer) then
                        destroyElement(trailer)
                    end
                    trailer_connections[vehicle] = nil
                end
                
                destroyElement(vehicle)
                removed_count = removed_count + 1
            end
        end
    end

    for ped, _ in pairs(population.peds) do
        if isElement(ped) and getElementType(ped) == "ped" and not isPedInVehicle(ped) then
            local px, py, pz = getElementPosition(ped)
            local should_remove = true

            -- Use pre-calculated positions
            for i = 1, #playerPositions do
                local pp = playerPositions[i]
                local dx, dy, dz = pp[1] - px, pp[2] - py, pp[3] - pz
                local distSq = dx*dx + dy*dy + dz*dz
                
                if distSq < safe_distance_sq then
                    should_remove = false
                    break
                end
            end

            if should_remove then
                destroyElement(ped)
                removed_count = removed_count + 1
            end
        end
    end
end

function countPopulationInSquares(trtype)
    for element, exists in pairs(population[trtype]) do
        if not isElement(element) then
            population[trtype][element] = nil
        elseif getElementType(element) == "ped" and isPedInVehicle(element) then
            -- Skip peds in vehicles
        else
            local x, y = getElementPosition(element)
            local dim = getElementDimension(element)
            x, y = math.floor(x/SQUARE_SIZE), math.floor(y/SQUARE_SIZE)

            for sy = y-2, y+2 do for sx = x-2, x+2 do
                local square = getPopulationSquare(sx, sy, dim)
                if sx == x and sy == y then
                    if not square then square = createPopulationSquare(sx, sy, dim, "despawn") end
                    square.list[trtype][element] = true
                end
                if square then square.count[trtype] = square.count[trtype]+1 end
            end end
        end
    end
end

function createPopulationSquare(x, y, dim, genmode)
    if not square_population then
        square_population = {}
        square_subtable_count[square_population] = 0
    end
    local square_dim = square_population[dim]
    if not square_dim then
        square_dim = {}
        square_subtable_count[square_dim] = 0
        square_population[dim] = square_dim
        square_subtable_count[square_population] = square_subtable_count[square_population]+1
    end
    local square_row = square_dim[y]
    if not square_row then
        square_row = {}
        square_subtable_count[square_row] = 0
        square_dim[y] = square_row
        square_subtable_count[square_dim] = square_subtable_count[square_dim]+1
    end
    local square = square_row[x]
    if not square then
        square = {}
        square_subtable_count[square] = 0
        square_row[x] = square
        square_subtable_count[square_row] = square_subtable_count[square_row]+1
    end
    square.count = {peds = 0, cars = 0, boats = 0, planes = 0}
    square.list = {peds = {}, cars = {}, boats = {}, planes = {}}
    square.gen_mode = genmode
    square.last_visit = getTickCount() -- Timestamp for GC
    return square
end

function destroyPopulationSquare(x, y, dim)
    if not square_population then return end
    local square_dim = square_population[dim]
    if not square_dim then return end
    local square_row = square_dim[y]
    if not square_row then return end
    local square = square_row[x]
    if not square then return end

    -- Clear remaining elements in square before destroying
    for trtype, list in pairs(square.list) do
        for element, _ in pairs(list) do
            if isElement(element) then destroyElement(element) end
        end
    end
    
    square_subtable_count[square] = nil
    square_row[x] = nil
    square_subtable_count[square_row] = square_subtable_count[square_row]-1
    if square_subtable_count[square_row] ~= 0 then return end
    square_subtable_count[square_row] = nil
    square_dim[y] = nil
    square_subtable_count[square_dim] = square_subtable_count[square_dim]-1
    if square_subtable_count[square_dim] ~= 0 then return end
    square_subtable_count[square_dim] = nil
    square_population[dim] = nil
    square_subtable_count[square_population] = square_subtable_count[square_population]-1
    if square_subtable_count[square_population] ~= 0 then return end
    square_subtable_count[square_population] = nil
    square_population = nil
end

-- Garbage Collector to clear unvisited squares
function garbageCollectSquares()
    if not square_population then return end
    local current_time = getTickCount()
    local removed_count = 0
    
    for dim, square_dim in pairs(square_population) do
        for y, square_row in pairs(square_dim) do
            for x, square in pairs(square_row) do
                -- If not visited for more than 30 seconds, clear
                if (current_time - square.last_visit) > 30000 then
                    destroyPopulationSquare(x, y, dim)
                    removed_count = removed_count + 1
                end
            end
        end
    end
    
    if removed_count > 0 then
        -- outputDebugString("GC: Removed "..removed_count.." unused traffic squares")
    end
end

function getPopulationSquare(x, y, dim)
    if not square_population then return end
    local square_dim = square_population[dim]
    if not square_dim then return end
    local square_row = square_dim[y]
    if not square_row then return end
    return square_row[x]
end

function generateTraffic()
    count_needed = 0 -- CRITICAL RESET: Prevents infinite spawn debt accumulation
    if not square_population then return end
    for dim, square_dim in pairs(square_population) do
        for y, square_row in pairs(square_dim) do
            for x, square in pairs(square_row) do
                local genmode = square.gen_mode
                if genmode == "spawn" then
                    spawnTrafficInSquare(x, y, dim, "peds")
                    spawnTrafficInSquare(x, y, dim, "cars")
                    spawnTrafficInSquare(x, y, dim, "boats")
                    spawnTrafficInSquare(x, y, dim, "planes")
                end
            end
        end
    end
end

skins = {0,7,9,10,11,12,13,14,15,16,17,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,43,44,46,47,48,49,50,53,54,55,56,57,58,59,60,61,66,67,68,69,70,71,72,73,76,77,78,79,82,83,84,88,89,91,93,94,95,96,98,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,141,142,143,147,148,150,151,153,157,158,159,160,161,162,170,173,174,175,181,182,183,184,185,186,187,188,196,197,198,199,200,201,202,206,210,214,215,216,217,218,219,220,221,222,223,224,225,226,227,228,229,231,232,233,234,235,236,239,240,241,242,247,248,250,253,254,255,258,259,260,261,262,263}
skincount = #skins

count_needed = 0

-- Spawn safety check (smart and optimized)
local function isSpawnSafe(x, y, z, radius)
    -- Check proximity to players (critical for visuals)
    -- Optimization: Check simple quadrant before calculating full dist3D if possible,
    -- but with few players direct iteration is fast enough.
    for player in pairs(players) do
        -- Using getElementPosition is fast, but avoid too many calls
        local px, py, pz = getElementPosition(player)
        
        -- Squared distance is faster (avoids math.sqrt)
        local dx, dy, dz = x - px, y - py, z - pz
        local distSq = dx*dx + dy*dy + dz*dz
        
        -- 40m^2 = 1600. If less than this, abort (too close)
        if distSq < 1600 then return false end
        
        -- Check field of view if close (< 80m, or 6400m^2)
        if distSq < 6400 then
            -- Optimization: Calculate dot product without normalizing complex vectors
            local _, _, prz = getElementRotation(player)
            local prad = math.rad(prz)
            local pdx, pdy = -math.sin(prad), math.cos(prad)
            
            -- Simplified dot product (normalized only by approximate distance would be better, but here direct)
            -- dot = (dir_player . dir_to_spawn)
            -- If spawn is in front, dot will be positive and large
            
            local dot = (dx * pdx + dy * pdy)
            -- We need to normalize 'dx, dy' to compare correctly with unit vector pdx,pdy
            -- approximate dist2D (or use distSq if we assume plane)
            local dist2D = math.sqrt(dx*dx + dy*dy)
            if dist2D > 0 then
                dot = dot / dist2D
                if dot > 0.6 then return false end -- Frontal angle
            end
        end
    end
    
    -- Removed getElementsWithinRange as it causes lag. 
    -- Physical collision is later checked by server_coldata.
    
    return true
end

function spawnTrafficInSquare(x, y, dim, trtype)
    local square_tm_id = square_id[y] and square_id[y][x]
    if not square_tm_id then return end
    local square = square_population and square_population[dim] and square_population[dim][y] and square_population[dim][y][x]
    if not square then return end

    local conns = square_conns[square_tm_id][trtype]
    local cpos1 = square_cpos1[square_tm_id][trtype]
    local cpos2 = square_cpos2[square_tm_id][trtype]
    local cdens = square_cdens[square_tm_id][trtype]
    local ttden = square_ttden[square_tm_id][trtype]
    
    -- SCALABILITY: Apply dynamic density modifier
    local effective_density = traffic_density[trtype] * (current_density_modifier or 1.0)
    count_needed = count_needed+math.max(ttden*effective_density-square.count[trtype]/25, 0)

    while count_needed >= 1 do
        local sqpos = ttden*math.random()
        local connpos
        local connnum = 1
        while true do
            if not cdens[connnum] then break end
            connpos = cdens[connnum]
            if sqpos > connpos then
                sqpos = sqpos-connpos
            else
                connpos = sqpos/connpos
                break
            end
            connnum = connnum+1
        end

        if not conns[connnum] then break end
        local connid = conns[connnum]
        connpos = cpos1[connnum]*(1-connpos)+cpos2[connnum]*connpos
        local n1, n2, nb = conn_n1[connid], conn_n2[connid], conn_nb[connid]
        
        local ll = (conn_lanes.left[connid] or 0)
        local rl = (conn_lanes.right[connid] or 0)

        local lanecount = ll+rl
        if lanecount == 0 and math.random(2) > 1 or lanecount ~= 0 and math.random(lanecount) > rl then
            n1, n2, ll, rl = n2, n1, rl, ll
            connpos = (nb and math.pi*0.5 or 1)-connpos
        end
        
        -- FINAL CORRECTION: Spawn in the first right lane (lane 1), if exists. Otherwise, in center (lane 0).
        local lane = (rl > 0) and 1 or 0
        
        local x, y, z
        local x1, y1, z1 = getNodeConnLanePos(n1, connid, lane, false)
        local x2, y2, z2 = getNodeConnLanePos(n2, connid, lane, true)
        local dx, dy, dz = x2-x1, y2-y1, z2-z1
        local rx = math.deg(math.atan2(dz, math.sqrt(dx*dx+dy*dy)))
        local rz
        if nb then
            local bx, by, bz = node_x[nb], node_y[nb], (z1+z2)*0.5
            local x1, y1, z1 = x1-bx, y1-by, z1-bz
            local x2, y2, z2 = x2-bx, y2-by, z2-bz
            local possin, poscos = math.sin(connpos), math.cos(connpos)
            x = bx+possin*x1+poscos*x2
            y = by+possin*y1+poscos*y2
            z = bz+possin*z1+poscos*z2
            local tx = -poscos
            local ty = possin
            tx, ty = x1*tx+x2*ty, y1*tx+y2*ty
            rz = -math.deg(math.atan2(tx, ty))
        else
            x = x1*(1-connpos)+x2*connpos
            y = y1*(1-connpos)+y2*connpos
            z = z1*(1-connpos)+z2*connpos
            rz = -math.deg(math.atan2(dx, dy))
        end

        local speed = conn_maxspeed[connid]/180
        local vmult = speed/math.sqrt(dx*dx+dy*dy+dz*dz)
        local vx, vy, vz = dx*vmult, dy*vmult, dz*vmult

        local model
        if trtype == "peds" then
            model = skins[math.random(skincount)]
        else
            local max_speed = conn_maxspeed[connid] or 50
            local is_highway = max_speed > 80
            local is_urban = (x > 44 and x < 2997 and y > -2892 and y < -596)
            
            -- 3% chance to spawn emergency vehicle
            local is_emergency = math.random() < 0.03
            
            if is_emergency then
                -- Emergency vehicles
                local emergency_models = {416, 407, 544, 596, 597, 598, 599}
                model = emergency_models[math.random(#emergency_models)]
            elseif is_highway then
                local highway_vehicles = {514, 515, 414, 455, 456, 578, 579, 600, 424, 573, 531, 408, 423, 588, 434, 443, 470, 524, 525, 402, 411, 415, 429, 451, 477, 494, 502, 503, 506, 541, 559, 560, 565, 587, 602, 603, 400, 401, 404, 405, 426, 436, 445, 458, 466, 467, 474, 475, 479, 480, 491, 492, 496, 500, 507, 462, 463, 468, 471, 521, 522, 581, 586}
                model = highway_vehicles[math.random(#highway_vehicles)]
            elseif is_urban then
                local urban_vehicles = {400, 401, 404, 405, 410, 412, 419, 421, 426, 436, 445, 458, 466, 467, 474, 475, 479, 480, 491, 492, 496, 500, 507, 516, 517, 518, 526, 527, 529, 533, 534, 535, 536, 540, 542, 545, 546, 547, 549, 550, 551, 554, 555, 558, 561, 562, 566, 567, 575, 576, 580, 582, 583, 585, 589, 596, 597, 598, 599, 604, 605, 420, 438, 462, 463, 468, 471, 521, 522, 581, 586, 482, 483, 508, 524, 525}
                model = urban_vehicles[math.random(#urban_vehicles)]
            else
                local rural_vehicles = {400, 401, 404, 405, 410, 412, 419, 421, 426, 436, 445, 458, 466, 467, 474, 475, 479, 480, 491, 492, 496, 500, 507, 514, 515, 414, 455, 456, 578, 579, 600, 424, 573, 531, 408, 423, 588, 434, 443, 470, 524, 525, 459, 479, 482, 495, 500, 543, 554, 568, 579, 600, 462, 463, 468, 471, 521, 522, 581, 586}
                model = rural_vehicles[math.random(#rural_vehicles)]
            end
        end
        local colx, coly, colz = x, y, z+(z_offset[model] or 1) 

        -- Check spawn safety before proceeding
        local safeRadius = (trtype == "cars") and 6.0 or 2.0
        local create = isSpawnSafe(x, y, z, safeRadius)
        
        if create and colcheck then
            local box = call(server_coldata, "createModelIntersectionBox", model, colx, coly, colz, rz)
            create = not call(server_coldata, "doesModelBoxIntersect", box, dim)
        end

        if create and trtype == "peds" then
            -- Check if urban area for bicycle chance
            local is_urban_area = (x > 44 and x < 2997 and y > -2892 and y < -596)
            local use_bicycle = is_urban_area and math.random() < 0.10  -- 10% chance in urban areas
            
            if use_bicycle then
                -- Create NPC on bicycle
                local bicycles = {509, 510, 481}  -- Bike, Mountain Bike, BMX
                local bike_model = bicycles[math.random(#bicycles)]
                local zoff = (z_offset[bike_model] or 0.5) + 0.3 -- Extra bump to avoid sinking
                
                local bike = createVehicle(bike_model, x, y, z+zoff, 0, 0, rz)
                setElementAlpha(bike, 0) -- Initially invisible
                setElementFrozen(bike, true) -- Initially frozen
                setElementCollisionsEnabled(bike, false) -- No collision to avoid deformation
                
                -- Reveal smoothly after 350ms (Delay increased to ensure stable physics)
                setTimer(function()
                    if isElement(bike) then
                        setElementAlpha(bike, 255)
                        setElementFrozen(bike, false)
                        setElementCollisionsEnabled(bike, true)
                    end
                end, 350, 1)

                setElementDimension(bike, dim)
                element_timers[bike] = {}
                addEventHandler("onElementDestroy", bike, removeCarFromListOnDestroy, false)
                addEventHandler("onVehicleExplode", bike, removeDestroyedCar, false)
                population.cars[bike] = true
                
                local ped = createPed(model, x, y, z+1, rz)
                warpPedIntoVehicle(ped, bike)
                setElementDimension(ped, dim)
                element_timers[ped] = {}
                addEventHandler("onElementDestroy", ped, removePedFromListOnDestroy, false)
                addEventHandler("onPedWasted", ped, removeDeadPed, false)
                population.peds[ped] = true
                -- initNPCSensors(ped, bike) -- DISABLED: Conflicts with npc_sensors.lua (AAA Sensors)
                
                if colcheck then call(server_coldata, "updateElementColData", bike) end
                
                -- Slower speed for bicycles (similar to fast walking)
                if not call(npc_hlc, "isHLCEnabled", ped) then
                    call(npc_hlc, "enableHLCForNPC", ped, "walk", 0.99, 25/180)  -- Bicycle speed
                end
                
                ped_lane[ped] = lane
                initPedRouteData(ped)
                addNodeToPedRoute(ped, n1)
                addNodeToPedRoute(ped, n2, nb)
                for nodenum = 1, 4 do addRandomNodeToPedRoute(ped) end
            else
                -- Normal pedestrians on foot
                local ped = createPed(model, x, y, z+1, rz)
                setElementDimension(ped, dim)
                element_timers[ped] = {}
                addEventHandler("onElementDestroy", ped, removePedFromListOnDestroy, false)
                addEventHandler("onPedWasted", ped, removeDeadPed, false)
                population.peds[ped] = true

                if colcheck then call(server_coldata, "updateElementColData", ped) end

                if not call(npc_hlc, "isHLCEnabled", ped) then
                    call(npc_hlc, "enableHLCForNPC", ped, "walk", 0.99, 40/180)
                end
                
                ped_lane[ped] = lane
                initPedRouteData(ped)
                addNodeToPedRoute(ped, n1)
                addNodeToPedRoute(ped, n2, nb)
                for nodenum = 1, 4 do addRandomNodeToPedRoute(ped) end
            end

        elseif create and trtype == "cars" then
            -- Added +0.2 to base offset to ensure it doesn't spawn buried
            local zoff = ((z_offset[model] or 1) + 0.2)/math.cos(math.rad(rx))
            local car = createVehicle(model, x, y, z+zoff, rx, 0, rz)
            setElementAlpha(car, 0) -- Initially invisible
            setElementFrozen(car, true) -- Initially frozen
            setElementCollisionsEnabled(car, false) -- No collision to avoid deformation

            -- Reveal smoothly after 350ms (Delay increased to ensure stable physics)
            setTimer(function()
                if isElement(car) then
                    setElementAlpha(car, 255)
                    setElementFrozen(car, false)
                    setElementCollisionsEnabled(car, true)
                end
            end, 350, 1)

            setElementDimension(car, dim)
            element_timers[car] = {}
            addEventHandler("onElementDestroy", car, removeCarFromListOnDestroy, false)
            addEventHandler("onVehicleExplode", car, removeDestroyedCar, false)
            population.cars[car] = true

            if colcheck then call(server_coldata, "updateElementColData", car) end

            -- Emergency vehicle skin mapping (vehicle model → appropriate ped skins)
            local EMERGENCY_SKINS = {
                [596] = {280, 281, 282},      -- Police LS → cops
                [597] = {280, 281, 282},      -- Police SF → cops
                [598] = {280, 281, 282},      -- Police LV → cops
                [599] = {285, 286},           -- Police Ranger → FBI/Army
                [416] = {274, 275},           -- Ambulance → paramedics
                [407] = {277, 278},           -- Fire Truck → firefighters
                [544] = {277, 278},           -- Fire Truck Ladder → firefighters
            }

            -- Select driver skin: emergency-appropriate or random civilian
            local driver_skin
            if EMERGENCY_SKINS[model] then
                local valid_skins = EMERGENCY_SKINS[model]
                driver_skin = valid_skins[math.random(#valid_skins)]
            else
                driver_skin = skins[math.random(skincount)]
            end

            local ped1 = createPed(driver_skin, x, y, z+1)
            warpPedIntoVehicle(ped1, car)
            setElementDimension(ped1, dim)
            element_timers[ped1] = {}
            addEventHandler("onElementDestroy", ped1, removePedFromListOnDestroy, false)
            addEventHandler("onPedWasted", ped1, removeDeadPed, false)
            population.peds[ped1] = true
            -- Check if vehicle is a motorcycle (skip arm animation and radio for bikes)
            local isBike = getVehicleType(car) == "Bike"
            
            -- 15% chance for driver to have arm-out-window animation (not on bikes)
            -- Animation and window handled client-side via element data
            if not isBike and math.random() < 0.15 then
                setElementData(car, "npc.driverWindowOpen", true, true)
                setElementData(ped1, "npc.armOutWindow", true, true)
            end
            
            -- 10% chance for NPC vehicle to have radio playing (skip emergency and bikes)
            if math.random() < 0.10 and not EMERGENCY_SKINS[model] and not isBike then
                setElementData(car, "npc.hasRadio", true, true)
            end
            
            -- Speed Personality System: Each NPC has individual speed variation
            -- Range: 0.85 to 1.15 (85% to 115% of base speed)
            local speedPersonality = 0.85 + (math.random() * 0.30)
            setElementData(ped1, "npc.speedPersonality", speedPersonality, false)  -- server-only, no sync needed
            
            -- Apply personality to base speed
            speed = speed * speedPersonality


            local maxpass = getVehicleMaxPassengers(model) or 0
            local passenger_chance = 0.5
            local category = getVehicleCategory(model)
            
            if category == "HEAVY" then passenger_chance = 0.2
            elseif category == "SPORTS" then passenger_chance = 0.3
            elseif category == "MOTORCYCLE" then passenger_chance = 0.15
            elseif category == "EMERGENCY" then 
                passenger_chance = 0.8  -- Ambulances/Police usually have a partner
                
                -- Emergency vehicles always have police radio
                setElementData(car, "npc.hasRadio", true, true)
                setElementData(car, "npc.radioType", "emergency", true)
                
                -- 50% chance to have active siren
                if math.random() < 0.5 then
                    setVehicleSirensOn(car, true)
                    emergency_vehicles[car] = true
                    -- Emergency vehicles with siren move faster
                    speed = speed * 1.3
                end
            end

            if maxpass >= 1 and math.random() < passenger_chance then
                -- Passenger skin: match emergency vehicle or random civilian
                local pass_skin
                if EMERGENCY_SKINS[model] then
                    local valid_skins = EMERGENCY_SKINS[model]
                    pass_skin = valid_skins[math.random(#valid_skins)]
                else
                    pass_skin = skins[math.random(skincount)]
                end
                local ped2 = createPed(pass_skin, x, y, z+1)
                warpPedIntoVehicle(ped2, car, 1)
                setElementDimension(ped2, dim)
                element_timers[ped2] = {}
                addEventHandler("onElementDestroy", ped2, removePedFromListOnDestroy, false)
                addEventHandler("onPedWasted", ped2, removeDeadPed, false)
                population.peds[ped2] = true
            end

            if maxpass >= 2 and math.random() < (passenger_chance * 0.5) then
                local pass3_skin
                if EMERGENCY_SKINS[model] then
                    local valid_skins = EMERGENCY_SKINS[model]
                    pass3_skin = valid_skins[math.random(#valid_skins)]
                else
                    pass3_skin = skins[math.random(skincount)]
                end
                local ped3 = createPed(pass3_skin, x, y, z+1)
                warpPedIntoVehicle(ped3, car, 2)
                setElementDimension(ped3, dim)
                element_timers[ped3] = {}
                addEventHandler("onElementDestroy", ped3, removePedFromListOnDestroy, false)
                addEventHandler("onPedWasted", ped3, removeDeadPed, false)
                population.peds[ped3] = true
            end

            if maxpass >= 3 and math.random() < (passenger_chance * 0.25) then
                local pass4_skin
                if EMERGENCY_SKINS[model] then
                    local valid_skins = EMERGENCY_SKINS[model]
                    pass4_skin = valid_skins[math.random(#valid_skins)]
                else
                    pass4_skin = skins[math.random(skincount)]
                end
                local ped4 = createPed(pass4_skin, x, y, z+1)
                warpPedIntoVehicle(ped4, car, 3)
                setElementDimension(ped4, dim)
                element_timers[ped4] = {}
                addEventHandler("onElementDestroy", ped4, removePedFromListOnDestroy, false)
                addEventHandler("onPedWasted", ped4, removeDeadPed, false)
                population.peds[ped4] = true
            end
            
            -- Trailers for trucks (Linerunner 514, Roadtrain 515)
            if category == "HEAVY" and (model == 514 or model == 515) and math.random() < 0.4 then
                local trailers = {435, 450, 584, 590, 591}
                local trailer_model = trailers[math.random(#trailers)]
                
                local trailer = createVehicle(trailer_model, x - 8, y, z+zoff, rx, 0, rz)
                setElementDimension(trailer, dim)
                
                if colcheck then call(server_coldata, "updateElementColData", trailer) end
                
                element_timers[trailer] = {}
                addEventHandler("onElementDestroy", trailer, removeCarFromListOnDestroy, false)
                addEventHandler("onVehicleExplode", trailer, removeDestroyedCar, false)
                population.cars[trailer] = true
                
                trailer_connections[car] = trailer
                
                setTimer(function()
                    if isElement(car) and isElement(trailer) then
                        attachTrailerToVehicle(car, trailer)
                    end
                end, 500, 1)
            end
            
            -- Tow Truck towing small/medium vehicles
            if model == 525 and math.random() < 0.4 then
                -- Small/medium vehicles that can be towed
                local towable_cars = {
                    400, 401, 404, 405, 410, 412, 419, 421,  -- Sedans
                    436, 445, 458, 466, 467, 474, 475, 479,  -- Compactos
                    480, 491, 492, 496, 500, 516, 517, 518,  -- Diversos
                    526, 527, 529, 533, 534, 535, 536, 540,  -- More cars
                    542, 545, 546, 547, 549, 550, 551, 555,  -- Diversos
                    558, 561, 562, 566, 567, 575, 576, 580,  -- Diversos
                    585, 589, 596, 597, 598, 599, 604, 605   -- Diversos
                }
                local towed_model = towable_cars[math.random(#towable_cars)]
                local towed_zoff = (z_offset[towed_model] or 1)
                
                -- Create towed vehicle behind tow truck
                local towed_car = createVehicle(towed_model, x - 6, y, z + towed_zoff, rx, 0, rz)
                setElementDimension(towed_car, dim)
                
                if colcheck then call(server_coldata, "updateElementColData", towed_car) end
                
                element_timers[towed_car] = {}
                addEventHandler("onElementDestroy", towed_car, removeCarFromListOnDestroy, false)
                addEventHandler("onVehicleExplode", towed_car, removeDestroyedCar, false)
                population.cars[towed_car] = true
                
                trailer_connections[car] = towed_car
                
                setTimer(function()
                    if isElement(car) and isElement(towed_car) then
                        attachTrailerToVehicle(car, towed_car)
                    end
                end, 500, 1)
            end

            setElementVelocity(car, vx, vy, vz)

            if not call(npc_hlc, "isHLCEnabled", ped1) then
                call(npc_hlc, "enableHLCForNPC", ped1, "walk", 0.99, speed)
            end

            ped_lane[ped1] = lane
            initPedRouteData(ped1)
            addNodeToPedRoute(ped1, n1)
            addNodeToPedRoute(ped1, n2, nb)
            for nodenum = 1, 4 do addRandomNodeToPedRoute(ped1) end
        end

        square.count[trtype] = square.count[trtype]+1
        count_needed = count_needed-1
    end
end

function removePedFromListOnDestroy()
    if element_timers[source] then
        for timer, exists in pairs(element_timers[source]) do
            killTimer(timer)
        end
        element_timers[source] = nil
    end
    population.peds[source] = nil
end

function removeDeadPed()
    element_timers[source][setTimer(destroyElement, 20000, 1, source)] = true
end

function removeCarFromListOnDestroy()
    -- If this vehicle is a truck with linked trailer, just clear the connection
    if trailer_connections[source] then
        trailer_connections[source] = nil
    end
    
    -- If this vehicle is a trailer of some truck, clear the connection
    for truck, trailer in pairs(trailer_connections) do
        if trailer == source then
            trailer_connections[truck] = nil
            break
        end
    end
    
    -- Clear from emergency vehicles list
    if emergency_vehicles[source] then
        emergency_vehicles[source] = nil
    end
    
    if element_timers[source] then
        for timer, exists in pairs(element_timers[source]) do
            if isTimer(timer) then
                killTimer(timer)
            end
        end
        element_timers[source] = nil
    end
    population.cars[source] = nil
end

function removeDestroyedCar()
    element_timers[source][setTimer(destroyElement, 60000, 1, source)] = true
end

-- Forced trailer re-hitch system (optimized)
-- Works for trucks (514, 515) and NPC tow trucks (525)
function forceReattachTrailers()
    local to_remove = {}  -- List of connections to remove (avoids modifying table during iteration)
    
    for truck, trailer in pairs(trailer_connections) do
        -- Check if both elements exist
        if not isElement(truck) or not isElement(trailer) then
            to_remove[#to_remove + 1] = truck
        else
            -- Check if it is an NPC vehicle (not player's)
            local driver = getVehicleController(truck)
            local is_npc_vehicle = false
            
            if driver and isElement(driver) then
                is_npc_vehicle = getElementType(driver) ~= "player"
            end
            
            -- Only process NPC vehicles
            if is_npc_vehicle then
                local attached = getVehicleTowedByVehicle(truck)
                if not attached then
                    local truck_x, truck_y, truck_z = getElementPosition(truck)
                    local trailer_x, trailer_y, trailer_z = getElementPosition(trailer)
                    local distance = getDistanceBetweenPoints3D(truck_x, truck_y, truck_z, trailer_x, trailer_y, trailer_z)
                    
                    -- If trailer is too far (>50m), teleport to near the truck
                    if distance > 50 then
                        -- Get truck rotation to position trailer behind
                        local rx, ry, rz = getElementRotation(truck)
                        local rad = math.rad(rz)
                        local behind_x = truck_x - math.sin(rad) * 8
                        local behind_y = truck_y - math.cos(rad) * 8
                        
                        setElementPosition(trailer, behind_x, behind_y, truck_z)
                        setElementRotation(trailer, rx, ry, rz)
                    end
                    
                    -- Try to re-hitch
                    attachTrailerToVehicle(truck, trailer)
                end
            else
                -- Vehicle is no longer NPC's (player took over), remove from list but do not destroy
                to_remove[#to_remove + 1] = truck
            end
        end
    end
    
    -- Clear invalid connections (outside main loop)
    for i = 1, #to_remove do
        trailer_connections[to_remove[i]] = nil
    end
end

function renewTrafficDynamic()
    if not square_population then return end
    
    local renewal_count = 0
    for dim, square_dim in pairs(square_population) do
        for y, square_row in pairs(square_dim) do
            for x, square in pairs(square_row) do
                if square.gen_mode == "spawn" then
                    -- Renew a small percentage of vehicles
                    if math.random() < 0.02 then
                        for vehicle, _ in pairs(square.list.cars) do
                            if math.random() < 0.1 and isElement(vehicle) then
                                local occupants = getVehicleOccupants(vehicle) or {}
                                destroyElement(vehicle)
                                for _, ped in pairs(occupants) do
                                    if isElement(ped) then destroyElement(ped) end
                                end
                                renewal_count = renewal_count + 1
                                break 
                            end
                        end
                    end
                    -- Renew a small percentage of pedestrians
                    if math.random() < 0.015 then
                        for ped, _ in pairs(square.list.peds) do
                            if isElement(ped) and getElementType(ped) == "ped" and not isPedInVehicle(ped) and math.random() < 0.08 then
                                destroyElement(ped)
                                renewal_count = renewal_count + 1
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Advanced sensor system for NPCs
local npc_sensors = {}
local SENSOR_DISTANCE = 25.0 -- Increased sensor range to see further
local SIDE_SENSOR_DISTANCE = 8.0
local BRAKE_DISTANCE = 8.0   -- Distance for full stop/emergency
local FOLLOW_DISTANCE = 20.0 -- Distance to start following/slowing down

-- Initialize sensors for an NPC
function initNPCSensors(ped, vehicle)
    if not ped or not vehicle then return end
    
    -- Wait for HLC to initialize first
    setTimer(function()
        if isElement(ped) and isElement(vehicle) then
            npc_sensors[ped] = {
                vehicle = vehicle,
                front_clear = true,
                left_clear = true,
                right_clear = true,
                following_vehicle = nil,
                last_check = 0,
                brake_intensity = 0,
                original_speed = 0.8,  -- Base speed
                hlc_controlled = true   -- Flag for cooperation
            }
        end
    end, 1500, 1)  -- Delay for HLC to establish
end

-- OPTIMIZATION: Function to find nearby vehicles using grid (avoids looping all cars)
function getVehiclesNearby(x, y, dim)
    if not square_population then return {} end
    
    local sx, sy = math.floor(x/SQUARE_SIZE), math.floor(y/SQUARE_SIZE)
    local vehicles = {}
    
    -- Check current and adjacent squares (3x3 grid)
    if square_population[dim] then
        for dy = -1, 1 do
            local row = square_population[dim][sy + dy]
            if row then
                for dx = -1, 1 do
                    local square = row[sx + dx]
                    if square and square.list and square.list.cars then
                        for car, _ in pairs(square.list.cars) do
                            table.insert(vehicles, car)
                        end
                    end
                end
            end
        end
    end
    return vehicles
end

-- Check obstacles using raycasting (OPTIMIZED)
function checkNPCObstacles(ped)
    local sensor_data = npc_sensors[ped]
    if not sensor_data or not isElement(sensor_data.vehicle) then return end
    
    local current_time = getTickCount()
    if current_time - sensor_data.last_check < 500 then return end -- Check every 500ms (was 100ms)
    sensor_data.last_check = current_time
    
    local vehicle = sensor_data.vehicle
    local vx, vy, vz = getElementPosition(vehicle)
    local _, _, rz = getElementRotation(vehicle)
    
    -- Calculate sensor directions
    local rad = math.rad(rz)
    local front_x = vx + math.sin(rad) * SENSOR_DISTANCE
    local front_y = vy + math.cos(rad) * SENSOR_DISTANCE
    
    local left_rad = rad - math.rad(45)
    local left_x = vx + math.sin(left_rad) * SIDE_SENSOR_DISTANCE
    local left_y = vy + math.cos(left_rad) * SIDE_SENSOR_DISTANCE
    
    local right_rad = rad + math.rad(45)
    local right_x = vx + math.sin(right_rad) * SIDE_SENSOR_DISTANCE
    local right_y = vy + math.cos(right_rad) * SIDE_SENSOR_DISTANCE
    
    -- Check front sensor
    local front_hit = false
    local closest_distance = SENSOR_DISTANCE
    local following_target = nil
    
    -- Use getElementsWithinRange to detect ALL vehicles (including players)
    local nearby_vehicles = getElementsWithinRange(vx, vy, vz, SENSOR_DISTANCE, "vehicle")
    

    
    for _, other_vehicle in ipairs(nearby_vehicles) do
        if other_vehicle ~= vehicle and isElement(other_vehicle) then
            local ox, oy, oz = getElementPosition(other_vehicle)
            local distance_to_vehicle = getDistanceBetweenPoints3D(vx, vy, vz, ox, oy, oz)
            
            if distance_to_vehicle < SENSOR_DISTANCE then
                -- Check if in front
                local angle_to_vehicle = math.deg(math.atan2(ox - vx, oy - vy))
                local vehicle_angle = rz
                local angle_diff = math.abs(angle_to_vehicle - vehicle_angle)
                if angle_diff > 180 then angle_diff = 360 - angle_diff end
                
                if angle_diff < 45 and distance_to_vehicle < closest_distance then
                    front_hit = true
                    closest_distance = distance_to_vehicle
                    following_target = other_vehicle
                end
            end
        end
    end
    
    sensor_data.front_clear = not front_hit
    sensor_data.following_vehicle = following_target
    
    -- Apply behavior based on sensors
    applyNPCSensorBehavior(ped, sensor_data, closest_distance)
end

-- Apply behavior based on sensors
function applyNPCSensorBehavior(ped, sensor_data, obstacle_distance)
    if not isElement(ped) or not isElement(sensor_data.vehicle) then return end
    
    local vehicle = sensor_data.vehicle
    
    if not sensor_data.front_clear then
        if obstacle_distance < BRAKE_DISTANCE then
            -- Signal HLC to brake via elementData
            setElementData(ped, "hlc_brake_signal", true)
            setElementData(ped, "hlc_target_speed", 0.1)
            sensor_data.brake_intensity = 1.0
            

            
        elseif obstacle_distance < FOLLOW_DISTANCE and sensor_data.following_vehicle then
            -- Follow front vehicle
            local target_speed = 0.3 + (obstacle_distance / FOLLOW_DISTANCE) * 0.4
            setElementData(ped, "hlc_brake_signal", false)
            setElementData(ped, "hlc_target_speed", target_speed)
            sensor_data.brake_intensity = 0.3
            
        else
            -- Reduce speed gradually
            local speed_factor = obstacle_distance / SENSOR_DISTANCE
            local target_speed = 0.4 + speed_factor * 0.4
            local speed_factor = obstacle_distance / SENSOR_DISTANCE
            local target_speed = 0.4 + speed_factor * 0.4
            setElementData(ped, "hlc_brake_signal", false)
            sensor_data.stop_begin = nil -- Reset stop counter
            setElementData(ped, "hlc_target_speed", target_speed)
            sensor_data.brake_intensity = 0.1
        end
    else
        -- Clear path - remove restrictions
        setElementData(ped, "hlc_brake_signal", false)
        setElementData(ped, "hlc_target_speed", sensor_data.original_speed)
        sensor_data.brake_intensity = 0
    end
end

-- System to apply sensor data to HLC smoothly
function updateHLCBasedOnSensors()
    for ped, sensor_data in pairs(npc_sensors) do
        if isElement(ped) and sensor_data.hlc_controlled then
            local brake_signal = getElementData(ped, "hlc_brake_signal")
            local target_speed = getElementData(ped, "hlc_target_speed")
            
            if target_speed and call(npc_hlc, "isHLCEnabled", ped) then
                -- Apply speed change gradually
                pcall(function()
                    call(npc_hlc, "setNPCDriveSpeed", ped, target_speed)
                end)
            end
            
            -- Clear old data
            if brake_signal == false then
                removeElementData(ped, "hlc_brake_signal")
                removeElementData(ped, "hlc_target_speed")
            end
        end
    end
end

-- Timer to check sensors
-- Timer to check sensors (DISABLED TO AVOID CONFLICT WITH NPC_HLC AAA SENSORS)
--[[
setTimer(function()
    -- Remove count limit to process all sensors
    for ped, _ in pairs(npc_sensors) do
        if isElement(ped) and getElementType(ped) == "ped" and isPedInVehicle(ped) then
            checkNPCObstacles(ped)
        else
            npc_sensors[ped] = nil
        end
    end
end, 500, 0) -- Timer every 500ms
]]

-- Clear sensors when NPC is destroyed
function cleanupNPCSensors()
    if npc_sensors[source] then
        -- Remove element data before clearing
        removeElementData(source, "hlc_brake_signal")
        removeElementData(source, "hlc_target_speed")
        npc_sensors[source] = nil
    end
end

addEventHandler("onElementDestroy", root, function()
    if getElementType(source) == "ped" then
        cleanupNPCSensors()
    end
end)

-- Prevent NPC vehicle theft
function preventVehicleTheft(player, seat, jacked)
    if seat == 0 and population.cars[source] then
        local driver = getVehicleController(source)
        if driver and isElement(driver) and getElementType(driver) ~= "player" then
            cancelEvent()
            outputChatBox("Você não pode roubar este veículo de NPC!", player, 255, 50, 50)
        end
    end
end
addEventHandler("onVehicleStartEnter", root, preventVehicleTheft)
