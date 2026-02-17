-- npc_sensors.lua (SERVER-SIDE)
-- NPC Sensor System v4.9
-- Reads sensor data from client (set via elementData)
-- Client does the raycast, server reads results and calculates braking
-- Features: Adaptive speed, curve detection, physics-based braking, frustration system

-- DEBUG CONTROL
DEBUG_SENSORS = false  -- Set to true for visual debug

function toggleSensorDebug(player)
	DEBUG_SENSORS = not DEBUG_SENSORS
	local msg = DEBUG_SENSORS and "ENABLED" or "DISABLED"
	outputChatBox("[Sensors v4.9] Debug: " .. msg, player or root, 0, 255, 100)
	-- Sync to all clients
	setElementData(root, "sensors.debug", DEBUG_SENSORS)
end
addCommandHandler("debugsensors", toggleSensorDebug)

-- Initialize debug state
setElementData(root, "sensors.debug", DEBUG_SENSORS)

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local MIN_SAFETY_DIST = 4.0
local DEADLOCK_TIME_MS = 2500

-- FRUSTRATION SYSTEM - Progressive phases when stuck
local FRUSTRATION_CONFIG = {
	HAZARD_START_MS = 8000,      -- 8s: Start hazard lights (pisca-alerta)
	HORN_START_MS = 10000,       -- 10s: Start honking
	HORN_INTERVAL_MS = 5000,     -- Honk pattern every 5 seconds
	DESPAWN_MS = 60000,          -- 60s: Failsafe despawn
	-- Honk pattern: 3 quick honks, pause, 2 quick honks
	HONK_QUICK_DURATION_MS = 200,   -- Each quick honk
	HONK_QUICK_PAUSE_MS = 150,      -- Pause between quick honks
}

-- State
local npc_stuck_info = {}
local npc_frustration = {}  -- Tracks frustration state per NPC

-- =============================================================================
-- HELPERS
-- =============================================================================
function getElementSpeed(element)
	if not isElement(element) then return 0 end
	local vx, vy, vz = getElementVelocity(element)
	return math.sqrt(vx*vx + vy*vy + vz*vz)
end

function getVehiclePhysicsProfile(vehicle)
	if not isElement(vehicle) then return 5.0, 3.2, 1.0 end  -- decel, width, lengthMultiplier
	local vType = getVehicleType(vehicle)
	-- Buses, trucks = slower decel, wider, longer
	if vType == "Monster Truck" or vType == "Bus" or vType == "Trailer" then
		return 2.5, 5.5, 2.0  -- much slower to stop, wider, 2x longer
	end
	local model = getElementModel(vehicle)
	-- Heavy vehicles (fire truck, garbage, etc)
	local heavy = {[403]=1,[406]=1,[407]=1,[408]=1,[414]=1,[431]=1,[455]=1,[514]=1,[515]=1,[578]=1,[609]=1}
	if heavy[model] then return 2.0, 5.0, 1.8 end
	-- Medium trucks
	local medium = {[413]=1,[414]=1,[440]=1,[456]=1,[478]=1,[498]=1,[499]=1,[500]=1,[524]=1,[573]=1}
	if medium[model] then return 3.5, 4.0, 1.5 end
	return 5.0, 3.2, 1.0
end

-- =============================================================================
-- ROUTE PREDICTION  
-- =============================================================================
function getRoutePrediction(npc)
	local nodes = ped_nodes and ped_nodes[npc]
	local current = ped_thisnode and ped_thisnode[npc]
	if not nodes or not current then return nil end
	
	local waypoints = {}
	for i = 0, 3 do
		local nodeId = nodes[current + i]
		if nodeId and node_x and node_y then
			local nx, ny = node_x[nodeId], node_y[nodeId]
			if nx and ny then
				table.insert(waypoints, {x = nx, y = ny})
			end
		end
	end
	
	if #waypoints < 2 then return nil end
	
	local turnDir = nil
	if #waypoints >= 3 then
		local v1x = waypoints[2].x - waypoints[1].x
		local v1y = waypoints[2].y - waypoints[1].y
		local v2x = waypoints[3].x - waypoints[2].x
		local v2y = waypoints[3].y - waypoints[2].y
		local cross = v1x * v2y - v1y * v2x
		if math.abs(cross) > 5.0 then
			turnDir = cross > 0 and "left" or "right"
		end
	end
	
	return { waypoints = waypoints, turnDir = turnDir }
end

-- =============================================================================
-- MAIN SENSOR FUNCTION (reads from client data)
-- =============================================================================
function getSurroundingThreats(npc, lookAtX, lookAtY, bendData)
	local vehicle = getPedOccupiedVehicle(npc) or npc
	if not isElement(vehicle) then return nil end
	
	local mySpeed = getElementSpeed(vehicle)
	
	-- Read sensor data from client (set by npc_sensors_c.lua)
	local sensorData = getElementData(npc, "npc.sensors")
	
	local threats = {}
	
	if sensorData then
		-- Front threat
		if sensorData.front then
			local frontEl = sensorData.front.element
			threats.front = {
				dist = sensorData.front.dist,
				speed = isElement(frontEl) and getElementSpeed(frontEl) or 0,
				closingSpeed = mySpeed - (isElement(frontEl) and getElementSpeed(frontEl) or 0),
				isPed = sensorData.front.isPed,
				element = frontEl
			}
		end
		
		-- Lateral threats
		if sensorData.side_left then
			threats.side_left = sensorData.side_left
		end
		if sensorData.side_right then
			threats.side_right = sensorData.side_right
		end
		if sensorData.front_left then
			threats.front_left = sensorData.front_left
		end
		if sensorData.front_right then
			threats.front_right = sensorData.front_right
		end
	end
	
	-- Set debug data for visualization (server route info + client sensor data combined)
	if DEBUG_SENSORS then
		local routeData = getRoutePrediction(npc)
		local debugInfo = getElementData(npc, "debug.sensor") or {}
		debugInfo.speed = math.floor(mySpeed * 180)
		debugInfo.route = routeData
		debugInfo.target = threats.front and threats.front.element or nil
		debugInfo.targetDist = threats.front and threats.front.dist or nil
		setElementData(npc, "debug.sensor", debugInfo)
	end
	
	return threats, mySpeed
end

-- =============================================================================
-- BRAKING FACTOR (v4.3 - improved for heavy vehicles)
-- =============================================================================
function calculateBrakingFactor(threats, mySpeed, npc)
	if not threats then return 1.0 end
	
	local front = threats.front
	if not front then return 1.0 end
	
	local dist = front.dist
	local closing = front.closingSpeed or 0
	
	-- Get vehicle physics profile
	local vehicle = getPedOccupiedVehicle(npc) or npc
	local decel, _, lengthMult = getVehiclePhysicsProfile(vehicle)
	
	-- Speed in km/h for easier tuning
	local speedKmh = mySpeed * 180
	
	-- EMERGENCY STOP
	if front.isPed and dist < 10.0 then return 0.0 end
	if dist < MIN_SAFETY_DIST then return 0.0 end
	
	-- Calculate stopping distance (physics-based)
	-- Formula: d = v² / (2 * a) + reaction distance
	local brakingDist = (mySpeed * mySpeed) / (2 * decel)
	
	-- Reaction distance increases with speed (driver reaction time ~1.5s)
	local reactionTime = 1.5
	local reactionDist = mySpeed * reactionTime
	
	-- Base stopping distance
	local stopDist = reactionDist + brakingDist
	
	-- Apply length multiplier for longer vehicles (need to start braking earlier)
	stopDist = stopDist * lengthMult
	
	-- High speed bonus (quadratic scaling for >60 km/h)
	if speedKmh > 60 then
		local speedBonus = ((speedKmh - 60) / 40) ^ 2 * 10  -- up to +10m at 100km/h
		stopDist = stopDist + speedBonus
	end
	
	-- Closing speed adjustment (more aggressive when approaching fast)
	if closing > 0.1 then
		-- Quadratic closing bonus for heavy closing speeds
		local closingBonus = closing * closing * 8
		stopDist = stopDist + closingBonus
	end
	
	-- Minimum safety margins
	stopDist = math.max(12.0, stopDist)  -- at least 12m
	
	-- Calculate factor
	if dist >= stopDist then return 1.0 end
	if dist <= MIN_SAFETY_DIST then return 0.0 end
	
	local factor = (dist - MIN_SAFETY_DIST) / (stopDist - MIN_SAFETY_DIST)
	
	-- Aggressive reduction when closing fast at high speed
	if closing > 0.3 and speedKmh > 40 then
		factor = factor * 0.4
	elseif closing > 0.2 then
		factor = factor * 0.6
	end
	
	return math.max(0.0, math.min(1.0, factor))
end

-- =============================================================================
-- DEADLOCK HANDLER (v4.6 - Fixed ID comparison & timing)
-- =============================================================================

-- Global spawn counter for unique element IDs
local npc_spawn_counter = 0

-- Assign unique spawn ID to a vehicle/ped
function assignSpawnID(element)
	if not isElement(element) then return end
	local existingID = getElementData(element, "npc.spawn_id")
	if not existingID then
		npc_spawn_counter = npc_spawn_counter + 1
		setElementData(element, "npc.spawn_id", npc_spawn_counter)
	end
end

-- Get spawn ID (assigns if not present)
function getSpawnID(element)
	if not isElement(element) then return 0 end
	local id = getElementData(element, "npc.spawn_id")
	if not id then
		assignSpawnID(element)
		id = getElementData(element, "npc.spawn_id") or 0
	end
	return id
end


-- Check if two vehicles are facing each other (head-on potential collision)
-- Returns true only if they are pointing at each other (opposite directions)
function isHeadOnCollision(myVehicle, otherVehicle)
	if not isElement(myVehicle) or not isElement(otherVehicle) then return false end
	
	-- Get rotations (heading)
	local _, _, myRot = getElementRotation(myVehicle)
	local _, _, theirRot = getElementRotation(otherVehicle)
	
	-- Normalize to 0-360
	myRot = myRot % 360
	theirRot = theirRot % 360
	
	-- Calculate difference in heading
	local diff = math.abs(myRot - theirRot)
	if diff > 180 then diff = 360 - diff end
	
	-- Head-on = approximately opposite directions (150-210 degrees difference)
	-- Same direction = approximately same heading (0-60 degrees difference)
	-- If diff > 120, they are mostly facing each other (head-on or close to it)
	return diff > 120
end

function handleDeadlock(npc, threat, speed)
	local myVehicle = getPedOccupiedVehicle(npc)
	
	-- Clear reverse mode only if currently active (avoid unnecessary sync)
	if myVehicle and getElementData(npc, "npc.reverse_mode") then
		setElementData(npc, "npc.reverse_mode", false)
	end
	
	-- Early exit conditions
	if not threat or threat.dist > 7.0 or speed > 0.05 then
		npc_stuck_info[npc] = nil
		return 1.0
	end
	
	local other = threat.element
	if not isElement(other) or getElementType(other) ~= "vehicle" then return 1.0 end
	
	if not myVehicle then return 1.0 end
	
	-- CRITICAL CHECK: Only handle head-on collisions, not normal following traffic
	if not isHeadOnCollision(myVehicle, other) then
		-- Same direction traffic - this is NOT a deadlock, just normal queue
		-- Reset timer and let normal braking handle it
		npc_stuck_info[npc] = nil
		return 1.0
	end
	
	local now = getTickCount()
	
	-- Timer management with fluctuation tolerance
	local stuckInfo = npc_stuck_info[npc]
	if not stuckInfo then
		npc_stuck_info[npc] = { startTime = now, target = other, lastSeen = now }
		return 1.0
	end
	
	-- If target changed but we saw original target recently (< 500ms), don't reset
	if stuckInfo.target ~= other then
		if (now - stuckInfo.lastSeen) < 500 then
			stuckInfo.lastSeen = now
		else
			npc_stuck_info[npc] = { startTime = now, target = other, lastSeen = now }
			return 1.0
		end
	else
		stuckInfo.lastSeen = now
	end
	
	if (now - stuckInfo.startTime) > DEADLOCK_TIME_MS then
		local myID = getSpawnID(myVehicle)
		local theirID = getSpawnID(other)
		
		-- Debug output
		if DEBUG_SENSORS then
			---outputDebugString(string.format("[Deadlock HEAD-ON] NPC %d vs %d, dist=%.1f", myID, theirID, threat.dist))
		end
		
		-- PRIORITY LOGIC: Lower ID = has priority (stays put)
		-- Higher ID = should yield (reverse)
		if myID > theirID then 
			-- I'm newer (higher ID), I should reverse
			if threat.dist < 6.0 then 
				setElementData(npc, "npc.reverse_mode", true)
				if DEBUG_SENSORS then
					---outputDebugString(string.format("[Deadlock] NPC %d REVERSING", myID))
				end
				return 0.0
			end
			return 0.0
		else
			-- I'm older (lower ID), I have priority - just wait
			if DEBUG_SENSORS then
				---outputDebugString(string.format("[Deadlock] NPC %d WAITING (priority)", myID))
			end
			return 0.0
		end
	end
	
	return 1.0
end

-- =============================================================================
-- INTERSECTION DETECTION
-- =============================================================================

function getIntersectionState(npc)
	local vehicle = getPedOccupiedVehicle(npc) or npc
	if not isElement(vehicle) then return nil end
	local speed = getElementSpeed(vehicle)
	if speed < 0.5 then return nil end
	
	local x, y, z = getElementPosition(vehicle)
	local vx, vy = getElementVelocity(vehicle)
	local vLen = math.sqrt(vx*vx + vy*vy)
	if vLen < 0.01 then return nil end
	local nvx, nvy = vx/vLen, vy/vLen
	
	local others = getElementsWithinRange(x, y, z, 30.0, "vehicle")
	for _, other in ipairs(others) do
		if other ~= vehicle then
			local ox, oy = getElementPosition(other)
			local ovx, ovy = getElementVelocity(other)
			local oSpeed = math.sqrt(ovx*ovx + ovy*ovy)
			if oSpeed > 1.0 then
				local dx, dy = ox - x, oy - y
				local dist = math.sqrt(dx*dx + dy*dy)
				if dist > 1.0 then
					local fwdDot = (dx*nvx + dy*nvy) / dist
					if fwdDot > 0.1 then
						local det = nvx * (-ovy) - nvy * (-ovx)
						if math.abs(det) > 0.1 then
							local t = (dx * (-ovy) - dy * (-ovx)) / det
							if t > 0 and t < 35.0 then
								local myTime = t / speed
								local ix, iy = x + nvx*t, y + nvy*t
								local theirDist = math.sqrt((ix-ox)^2 + (iy-oy)^2)
								local theirTime = theirDist / oSpeed
								if math.abs(myTime - theirTime) < 3.0 and theirTime < myTime + 0.8 then
									return "yield"
								end
							end
						end
					end
				end
			end
		end
	end
	return nil
end

-- =============================================================================
-- SPEED GOVERNOR (v4.4 - Adaptive Speed Control)
-- Modulates route speed based on sensors, curves, and traffic
-- =============================================================================

-- Calculate curve severity factor (0.4 = sharp turn, 1.0 = straight)
function getCurveFactor(npc)
	local route = getRoutePrediction(npc)
	if not route or not route.waypoints or #route.waypoints < 3 then
		return 1.0  -- No curve detected
	end
	
	local wp = route.waypoints
	
	-- Calculate angle between segments
	local v1x = wp[2].x - wp[1].x
	local v1y = wp[2].y - wp[1].y
	local v2x = wp[3].x - wp[2].x
	local v2y = wp[3].y - wp[2].y
	
	local len1 = math.sqrt(v1x*v1x + v1y*v1y)
	local len2 = math.sqrt(v2x*v2x + v2y*v2y)
	
	if len1 < 1 or len2 < 1 then return 1.0 end
	
	-- Normalize
	v1x, v1y = v1x/len1, v1y/len1
	v2x, v2y = v2x/len2, v2y/len2
	
	-- Dot product = cos(angle)
	local dot = v1x*v2x + v1y*v2y
	dot = math.max(-1, math.min(1, dot))  -- Clamp
	
	-- Cross product magnitude for turn direction
	local cross = math.abs(v1x*v2y - v1y*v2x)
	
	-- If angle is small (dot close to 1), no reduction
	if dot > 0.9 then return 1.0 end
	
	-- Sharp turn (dot < 0.5 means >60° turn)
	if dot < 0.5 then
		return 0.4  -- Reduce to 40% speed
	elseif dot < 0.7 then
		return 0.6  -- Reduce to 60% speed
	elseif dot < 0.85 then
		return 0.8  -- Reduce to 80% speed
	end
	
	return 1.0
end

-- Get distance to next curve (for anticipation)
function getDistanceToNextCurve(npc)
	local route = getRoutePrediction(npc)
	if not route or not route.waypoints or #route.waypoints < 2 then
		return 999
	end
	
	local vehicle = getPedOccupiedVehicle(npc)
	if not vehicle then return 999 end
	
	local vx, vy = getElementPosition(vehicle)
	local wp = route.waypoints[2]
	
	return math.sqrt((wp.x - vx)^2 + (wp.y - vy)^2)
end

-- Get all speed modifiers
function getSpeedModifiers(npc)
	local mods = { braking = 1.0, curve = 1.0, traffic = 1.0 }
	
	-- 1. BRAKING FACTOR (from sensors)
	local threats, speed = getSurroundingThreats(npc)
	if threats then
		mods.braking = calculateBrakingFactor(threats, speed, npc)
		
		-- Handle deadlock
		if threats.front then
			local deadlockMod = handleDeadlock(npc, threats.front, speed)
			if deadlockMod ~= 1.0 then
				mods.braking = deadlockMod
			end
		end
	end
	
	-- 2. CURVE FACTOR (anticipate curves)
	local curveFactor = getCurveFactor(npc)
	local distToCurve = getDistanceToNextCurve(npc)
	
	-- Apply curve factor gradually based on distance
	if distToCurve < 40 then
		-- Close to curve, apply full reduction
		mods.curve = curveFactor
	elseif distToCurve < 70 then
		-- Approaching curve, blend factor
		local blend = (70 - distToCurve) / 30
		mods.curve = 1.0 - (1.0 - curveFactor) * blend
	end
	
	-- 3. TRAFFIC FACTOR (future: based on traffic density)
	-- mods.traffic = getTrafficDensityFactor(npc)
	
	return mods
end

-- Get adaptive (modulated) speed
function getAdaptiveSpeed(npc)
	-- IMPORTANT: use BASE route speed, not current (which was already modified)
	local baseSpeed = getBaseSpeed(npc)
	local mods = getSpeedModifiers(npc)
	
	local finalSpeed = baseSpeed * mods.braking * mods.curve * mods.traffic
	
	-- Minimum speed to prevent complete stop (unless braking = 0)
	if mods.braking > 0 then
		finalSpeed = math.max(0.05, finalSpeed)
	end
	
	return finalSpeed, mods
end

-- Store original route speeds (fallback cache)
local npc_base_speed = {}

-- Save base speed when route sets it
function saveBaseSpeed(npc, speed)
	npc_base_speed[npc] = speed
	-- Also persist in elementData to avoid losing
	setElementData(npc, "npc_hlc:base_speed", speed)
end

-- Get base route speed (prioridade: elementData > cache > drive_speed)
function getBaseSpeed(npc)
	-- First try elementData (persistent, set by setNPCDriveSpeed)
	local baseFromData = getElementData(npc, "npc_hlc:base_speed")
	if baseFromData and baseFromData > 0 then
		return baseFromData
	end
	-- Fallback to local cache
	if npc_base_speed[npc] and npc_base_speed[npc] > 0 then
		return npc_base_speed[npc]
	end
	-- Last fallback: current drive_speed
	return getElementData(npc, "npc_hlc:drive_speed") or 0.5
end

-- =============================================================================
-- FRUSTRATION SYSTEM - Progressive reactions when stuck
-- =============================================================================

-- Play honk pattern: 3 quick honks, pause, 2 quick honks
function playHonkPattern(npc)
	if not isElement(npc) then return end
	
	local quick = FRUSTRATION_CONFIG.HONK_QUICK_DURATION_MS
	local pause = FRUSTRATION_CONFIG.HONK_QUICK_PAUSE_MS
	
	-- Pattern: ON-off-ON-off-ON-pause-ON-off-ON
	-- Timing: 0, 350, 700, 1050, 1400, 1750
	local pattern = {
		{0, true},           -- Honk 1 ON
		{quick, false},      -- Honk 1 OFF
		{quick + pause, true},     -- Honk 2 ON
		{quick*2 + pause, false},  -- Honk 2 OFF
		{quick*2 + pause*2, true}, -- Honk 3 ON
		{quick*3 + pause*2, false}, -- Honk 3 OFF (end of 3)
		{quick*3 + pause*3 + 300, true},  -- Pause then Honk 4 ON
		{quick*4 + pause*3 + 300, false}, -- Honk 4 OFF
		{quick*4 + pause*4 + 300, true},  -- Honk 5 ON
		{quick*5 + pause*4 + 300, false}, -- Honk 5 OFF (end of 2)
	}
	
	for _, step in ipairs(pattern) do
		setTimer(function()
			if isElement(npc) then
				setElementData(npc, "npc.honking", step[2])
			end
		end, step[1], 1)
	end
end

-- Check if NPC is waiting in a normal traffic queue (behind someone going same direction)
function isInTrafficQueue(npc)
	local vehicle = getPedOccupiedVehicle(npc)
	if not vehicle then return false end
	
	-- Get sensor data to see what's in front
	local threat = getElementData(npc, "sensor.frontal")
	if not threat or not threat.element then return false end
	
	local other = threat.element
	if not isElement(other) or getElementType(other) ~= "vehicle" then return false end
	
	-- Check if both are going the same direction (not head-on)
	local _, _, myRot = getElementRotation(vehicle)
	local _, _, theirRot = getElementRotation(other)
	
	myRot = myRot % 360
	theirRot = theirRot % 360
	
	local diff = math.abs(myRot - theirRot)
	if diff > 180 then diff = 360 - diff end
	
	-- Same direction = diff < 60 degrees = normal queue, don't frustrate
	return diff < 60
end

-- Helper to check if NPC is stopped at red light
function isWaitingForTrafficLight(npc)
	local thistask = getElementData(npc, "npc_hlc:thistask")
	if thistask then
		local task = getElementData(npc, "npc_hlc:task."..thistask)
		if task and task[1] == "waitForGreenLight" then
			return true
		end
	end
	return false
end

-- Update frustration state for an NPC
function updateFrustration(npc, isStuck)
	local vehicle = getPedOccupiedVehicle(npc)
	if not vehicle then return end
	
	local now = getTickCount()
	
	if not isStuck then
		-- NPC is moving - reset frustration
		if npc_frustration[npc] then
			-- Clear hazard lights (set both to false, clear emergency flag)
			setElementData(vehicle, "emergency_light", false)
			-- Stop horn
			setElementData(npc, "npc.honking", false)
			npc_frustration[npc] = nil
		end
		return
	end
	
	-- Don't get frustrated if waiting in normal traffic queue
	if isInTrafficQueue(npc) then
		-- Reset frustration if we're just in queue
		if npc_frustration[npc] then
			setElementData(vehicle, "emergency_light", false)
			setElementData(npc, "npc.honking", false)
			npc_frustration[npc] = nil
		end
		return
	end

	-- FIX: Do not accumulate frustration if stopped at red light
	if isWaitingForTrafficLight(npc) then
		-- Reset frustration if it was active
		if npc_frustration[npc] then
			setElementData(vehicle, "emergency_light", false)
			setElementData(npc, "npc.honking", false)
			npc_frustration[npc] = nil
		end
		return
	end
	
	-- Initialize frustration tracking
	if not npc_frustration[npc] then
		npc_frustration[npc] = {
			startTime = now,
			lastHonkPattern = 0,
			hazardActive = false
		}
	end
	
	local frust = npc_frustration[npc]
	local timeStuck = now - frust.startTime
	
	-- Phase 1: Hazard lights (pisca-alerta) after HAZARD_START_MS
	if timeStuck >= FRUSTRATION_CONFIG.HAZARD_START_MS and not frust.hazardActive then
		frust.hazardActive = true
		-- Use emergency_light flag for hazard (both sides blink together)
		setElementData(vehicle, "emergency_light", true)
		if DEBUG_SENSORS then
			---outputDebugString("[Frustration] NPC activating hazard lights")
		end
	end
	
	-- Phase 2: Honking pattern after HORN_START_MS
	if timeStuck >= FRUSTRATION_CONFIG.HORN_START_MS then
		if now - frust.lastHonkPattern >= FRUSTRATION_CONFIG.HORN_INTERVAL_MS then
			frust.lastHonkPattern = now
			playHonkPattern(npc)
			if DEBUG_SENSORS then
				---outputDebugString("[Frustration] NPC playing honk pattern (3+2)")
			end
		end
	end
	
	-- Phase 3: Start fade-out despawn after DESPAWN_MS
	if timeStuck >= FRUSTRATION_CONFIG.DESPAWN_MS and not frust.fadingOut then
		frust.fadingOut = true
		startFadeOutDespawn(npc, vehicle)
		return
	end
end

-- Smooth fade-out despawn - fades vehicle and all occupants to alpha 0, then destroys
local FADE_DURATION_MS = 2000  -- 2 seconds fade
local FADE_STEPS = 20          -- 20 steps = every 100ms

function startFadeOutDespawn(npc, vehicle)
	if not isElement(vehicle) then
		-- No vehicle, just destroy NPC
		if isElement(npc) then destroyElement(npc) end
		return
	end
	
	-- Get all occupants before starting fade
	local occupants = {}
	for seat = 0, getVehicleMaxPassengers(vehicle) do
		local occupant = getVehicleOccupant(vehicle, seat)
		if occupant and isElement(occupant) then
			table.insert(occupants, occupant)
		end
	end
	
	if DEBUG_SENSORS then
		---outputDebugString(string.format("[Frustration] Starting fade-out for vehicle with %d occupants", #occupants))
	end
	
	local stepInterval = FADE_DURATION_MS / FADE_STEPS
	local alphaStep = 255 / FADE_STEPS
	local currentStep = 0
	
	-- Create fade timer
	setTimer(function()
		currentStep = currentStep + 1
		local newAlpha = math.max(0, 255 - (alphaStep * currentStep))
		
		-- Fade vehicle
		if isElement(vehicle) then
			setElementAlpha(vehicle, newAlpha)
		end
		
		-- Fade all occupants
		for _, occupant in ipairs(occupants) do
			if isElement(occupant) then
				setElementAlpha(occupant, newAlpha)
			end
		end
		
		-- Final step - destroy everything
		if currentStep >= FADE_STEPS then
			-- Destroy all occupants first
			for _, occupant in ipairs(occupants) do
				if isElement(occupant) then
					npc_frustration[occupant] = nil
					destroyElement(occupant)
				end
			end
			-- Then destroy vehicle
			if isElement(vehicle) then
				destroyElement(vehicle)
			end
			
			if DEBUG_SENSORS then
				---outputDebugString("[Frustration] Fade-out complete, elements destroyed")
			end
		end
	end, stepInterval, FADE_STEPS)
end

-- Check if NPC is stuck (very low speed for extended time)
function isNPCStuck(npc)
	local vehicle = getPedOccupiedVehicle(npc)
	if not vehicle then return false end
	
	local speed = getElementSpeed(vehicle)
	-- Consider stuck if speed < 0.02 (~3.6 km/h)
	return speed < 0.02
end

-- =============================================================================
-- SPEED UPDATE TIMER (applies adaptive speed continuously)
-- =============================================================================
local SPEED_UPDATE_INTERVAL = 150  -- ms
local NPC_PROCESS_DISTANCE_SQ = 80000  -- 282m² (sqrt(80000) ≈ 282m)
local SPEED_CHUNK_SIZE = 15  -- Process max 15 NPCs per tick
local speed_npc_list = {}  -- Ordered list for chunking
local speed_npc_index = 1
local speed_list_update = 0
local SPEED_LIST_INTERVAL = 1000  -- Rebuild NPC list every 1s
local slow_npc_skip = {}  -- { [npc] = last_process_time } for slow NPCs

setTimer(function()
	local now = getTickCount()
	
	-- Rebuild NPC list periodically (not every tick)
	if now - speed_list_update > SPEED_LIST_INTERVAL then
		speed_npc_list = {}
		for npc in pairs(all_npcs or {}) do
			if isElement(npc) and isPedInVehicle(npc) then
				speed_npc_list[#speed_npc_list + 1] = npc
			end
		end
		speed_list_update = now
		if speed_npc_index > #speed_npc_list then speed_npc_index = 1 end
	end
	
	local npc_count = #speed_npc_list
	if npc_count == 0 then return end
	
	-- Cache player positions once per tick
	local playerPositions = {}
	local players = getElementsByType("player")
	for i=1, #players do
		local player = players[i]
		local px, py, pz = getElementPosition(player)
		playerPositions[#playerPositions + 1] = {px, py, pz}
	end
	
	-- Process chunk of NPCs
	local chunk_end = math.min(speed_npc_index + SPEED_CHUNK_SIZE - 1, npc_count)
	
	for idx = speed_npc_index, chunk_end do
		local npc = speed_npc_list[idx]
		if not isElement(npc) or not isPedInVehicle(npc) then
			-- Skip invalid, will be cleaned on next list rebuild
		else
			-- Proximity check to any player
			local shouldProcess = false
			local npcX, npcY, npcZ = getElementPosition(npc)
			
			for i = 1, #playerPositions do
				local pp = playerPositions[i]
				local dx, dy, dz = npcX - pp[1], npcY - pp[2], npcZ - pp[3]
				if (dx*dx + dy*dy + dz*dz) < NPC_PROCESS_DISTANCE_SQ then
					shouldProcess = true
					break
				end
			end
			
			if shouldProcess then
				-- THROTTLE: Slow/stopped NPCs process less often (every 500ms)
				local vehicle = getPedOccupiedVehicle(npc)
				local npcSpeed = vehicle and getElementSpeed(vehicle) or 0
				
				if npcSpeed < 0.02 then
					local lastSlow = slow_npc_skip[npc] or 0
					if now - lastSlow < 500 then
						-- Skip this tick for slow NPC
						shouldProcess = false
					else
						slow_npc_skip[npc] = now
					end
				else
					slow_npc_skip[npc] = nil
				end
			end
			
			if shouldProcess then
				-- Skip speed adjustments if vehicle is fleeing from gunshots
				local isFleeing = getElementData(npc, "vehicle.fleeing")
				if isFleeing then
					if DEBUG_SENSORS then
						local debugInfo = getElementData(npc, "debug.sensor") or {}
						debugInfo.fleeing = true
						setElementData(npc, "debug.sensor", debugInfo)
					end
				else
					-- Ensure vehicle has spawn ID for deadlock resolution
					local vehicle = getPedOccupiedVehicle(npc)
					if vehicle then assignSpawnID(vehicle) end
					
					local adaptiveSpeed, mods = getAdaptiveSpeed(npc)
					local currentSpeed = getElementData(npc, "npc_hlc:drive_speed") or 0.5
					
					-- Update frustration system
					local stuck = isNPCStuck(npc)
					updateFrustration(npc, stuck)
					
					if DEBUG_SENSORS then
						local debugInfo = getElementData(npc, "debug.sensor") or {}
						debugInfo.modifiers = mods
						debugInfo.baseSpeed = getBaseSpeed(npc)
						debugInfo.adaptiveSpeed = adaptiveSpeed
						debugInfo.stuck = stuck
						setElementData(npc, "debug.sensor", debugInfo)
					end
					
					-- Apply new speed if significantly different (>3%)
					if math.abs(adaptiveSpeed - currentSpeed) > currentSpeed * 0.03 then
						setElementData(npc, "npc_hlc:drive_speed", adaptiveSpeed)
					end
				end
			else
				-- NPC distant or slow-skipped: reset frustration silently
				if npc_frustration[npc] then
					local vehicle = getPedOccupiedVehicle(npc)
					if vehicle and isElement(vehicle) then
						setElementData(vehicle, "emergency_light", false)
					end
					setElementData(npc, "npc.honking", false)
					npc_frustration[npc] = nil
				end
			end
		end
	end
	
	-- Advance chunk index
	speed_npc_index = chunk_end + 1
	if speed_npc_index > npc_count then speed_npc_index = 1 end
end, SPEED_UPDATE_INTERVAL, 0)

-- Cleanup on NPC destroy
addEventHandler("onElementDestroy", root, function()
	if getElementType(source) == "ped" then
		npc_base_speed[source] = nil
		npc_stuck_info[source] = nil
		npc_frustration[source] = nil
		slow_npc_skip[source] = nil
	end
end)
