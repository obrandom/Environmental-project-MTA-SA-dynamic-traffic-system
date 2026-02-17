-- sensor_debug.lua (CLIENT-SIDE) - FIXED VERSION v4.7
-- NPC Sensor Visualization
-- FIX: Target larger and more visible + persistent cache

-- Cache of last valid debug state per NPC
local lastValidDebug = {}

function renderSensorDebug()
	local peds = getElementsByType("ped", root, true)
	local camX, camY, camZ = getCameraMatrix()
	
	for _, ped in ipairs(peds) do
		local debugInfo = getElementData(ped, "debug.sensor")
		
		-- FIX: If no current debug info, use last valid state
		if not debugInfo or not debugInfo.rays then
			debugInfo = lastValidDebug[ped]
		else
			-- Update cache with valid data
			lastValidDebug[ped] = debugInfo
		end
		
		if debugInfo and debugInfo.rays then
			local veh = getPedOccupiedVehicle(ped)
			if veh then
				local x, y, z = getElementPosition(veh)
				local dist = getDistanceBetweenPoints3D(camX, camY, camZ, x, y, z)
				
				if dist < 100.0 then
					local _, _, rz = getElementRotation(veh)
					local rad = math.rad(rz)
					local rightX, rightY = math.cos(rad), math.sin(rad)
					
					-- 1. RAYCAST RESULTS
					if debugInfo.origin then
						drawRaycastResults(debugInfo)
					end
					
					-- 2. LATERAL ZONES
					if debugInfo.lateral then
						drawLateralZones(x, y, z, rightX, rightY, debugInfo.lateral)
					end
					
					-- 3. TARGET (IMPROVED - LARGER AND MORE VISIBLE)
					if debugInfo.target and isElement(debugInfo.target) then
						local tx, ty, tz = getElementPosition(debugInfo.target)
						
						-- Thicker line for target
						dxDrawLine3D(x, y, z + 0.5, tx, ty, tz + 0.5, tocolor(255, 0, 0, 255), 4)
						
						-- LARGER sphere around target (3.0 instead of 1.0)
						drawWireSphere(tx, ty, tz + 0.5, 3.0, 255, 0, 0, 255)
						
						-- Additional smaller internal sphere for better visualization
						drawWireSphere(tx, ty, tz + 0.5, 1.5, 255, 100, 100, 200)
						
						-- Vertical marker (light column)
						for i = 0, 4 do
							local offsetZ = tz + i * 0.5
							dxDrawLine3D(tx - 0.8, ty, offsetZ, tx + 0.8, ty, offsetZ, tocolor(255, 0, 0, 180), 2)
							dxDrawLine3D(tx, ty - 0.8, offsetZ, tx, ty + 0.8, offsetZ, tocolor(255, 0, 0, 180), 2)
						end
						
						-- LARGER distance text
						local sx, sy = getScreenFromWorldPosition(tx, ty, tz + 2.5)
						if sx then
							local tDist = debugInfo.targetDist or 0
							
							-- Background for text
							dxDrawRectangle(sx - 40, sy - 15, 80, 30, tocolor(0, 0, 0, 180))
							
							-- Main text
							dxDrawText(string.format("TARGET\n%.1fm", tDist), sx, sy, sx, sy, 
								tocolor(255, 50, 50, 255), 1.5, "default-bold", "center", "center")
						end
					end
					
					-- 4. SPEED + MODIFIERS
					local sx, sy = getScreenFromWorldPosition(x, y, z + 2.5)
					if sx then
						local scale = math.max(0.5, 1.2 - dist/60)
						
						-- Background for speed
						dxDrawRectangle(sx - 35, sy - 12, 70, 24, tocolor(0, 0, 0, 150))
						
						dxDrawText(string.format("%d km/h", debugInfo.speed or 0), 
							sx, sy, sx, sy, tocolor(255,255,255), scale, "default-bold", "center")
						
						-- Show modifiers if available
						if debugInfo.modifiers then
							local m = debugInfo.modifiers
							local brakingPct = math.floor(m.braking * 100)
							local curvePct = math.floor(m.curve * 100)
							
							-- Color based on braking
							local modColor = tocolor(100, 255, 100, 255)
							if m.braking < 0.3 then 
								modColor = tocolor(255, 0, 0, 255)  -- Red: strong braking
							elseif m.braking < 0.7 then 
								modColor = tocolor(255, 200, 0, 255)  -- Yellow: medium braking
							end
							
							-- Background for modifiers
							dxDrawRectangle(sx - 45, sy + 14, 90, 20, tocolor(0, 0, 0, 150))
							
							local modText = string.format("Brake:%d%% Curve:%d%%", brakingPct, curvePct)
							dxDrawText(modText, sx, sy + 24, sx, sy + 24, modColor, scale * 0.75, "default-bold", "center")
						end
					end
				end
			end
		end
	end
end
addEventHandler("onClientRender", root, renderSensorDebug)

-- =============================================================================
-- DRAW RAYCAST RESULTS
-- =============================================================================
function drawRaycastResults(debugInfo)
	local origin = debugInfo.origin
	if not origin then return end
	
	for _, ray in ipairs(debugInfo.rays) do
		local r, g, b = 0, 255, 100  -- green for front
		if ray.zone == "front_left" or ray.zone == "front_right" then
			r, g, b = 255, 200, 0  -- yellow
		end
		
		local alpha = ray.hit and 220 or 80
		local col = tocolor(r, g, b, alpha)
		local width = ray.hit and 2.5 or 1.2
		
		dxDrawLine3D(origin.x, origin.y, origin.z, ray.endX, ray.endY, ray.endZ, col, width)
		
		if ray.hit then
			-- Hit marker (X) - larger
			dxDrawLine3D(ray.endX - 0.5, ray.endY, ray.endZ, ray.endX + 0.5, ray.endY, ray.endZ, col, 2.5)
			dxDrawLine3D(ray.endX, ray.endY - 0.5, ray.endZ, ray.endX, ray.endY + 0.5, ray.endZ, col, 2.5)
		end
	end
end

-- =============================================================================
-- DRAW LATERAL ZONES
-- =============================================================================
function drawLateralZones(x, y, z, rightX, rightY, lateral)
	local markerZ = z + 0.5
	local range = 6.0
	
	-- Left
	local leftDist = lateral.left or range
	local leftCol = lateral.left and tocolor(255, 128, 0, 220) or tocolor(255, 128, 0, 60)
	local lx, ly = x - rightX * leftDist, y - rightY * leftDist
	dxDrawLine3D(x, y, markerZ, lx, ly, markerZ, leftCol, 2)
	if lateral.left then
		drawWireSphere(lx, ly, markerZ, 0.8, 255, 128, 0, 220)
	end
	
	-- Right
	local rightDist = lateral.right or range
	local rightCol = lateral.right and tocolor(255, 128, 0, 220) or tocolor(255, 128, 0, 60)
	local rx, ry = x + rightX * rightDist, y + rightY * rightDist
	dxDrawLine3D(x, y, markerZ, rx, ry, markerZ, rightCol, 2)
	if lateral.right then
		drawWireSphere(rx, ry, markerZ, 0.8, 255, 128, 0, 220)
	end
end

-- =============================================================================
-- WIRE SPHERE
-- =============================================================================
function drawWireSphere(x, y, z, radius, r, g, b, alpha)
	local segs = 12  -- More segments for smoother circle
	local col = tocolor(r, g, b, alpha)
	
	-- Horizontal circle
	for i = 0, segs - 1 do
		local a1 = math.rad((i / segs) * 360)
		local a2 = math.rad(((i+1) / segs) * 360)
		dxDrawLine3D(x+math.cos(a1)*radius, y+math.sin(a1)*radius, z,
			x+math.cos(a2)*radius, y+math.sin(a2)*radius, z, col, 2)
	end
	
	-- Vertical circle 1
	for i = 0, segs - 1 do
		local a1 = math.rad((i / segs) * 360)
		local a2 = math.rad(((i+1) / segs) * 360)
		dxDrawLine3D(x+math.cos(a1)*radius, y, z+math.sin(a1)*radius,
			x+math.cos(a2)*radius, y, z+math.sin(a2)*radius, col, 2)
	end
	
	-- Vertical circle 2 (perpendicular)
	for i = 0, segs - 1 do
		local a1 = math.rad((i / segs) * 360)
		local a2 = math.rad(((i+1) / segs) * 360)
		dxDrawLine3D(x, y+math.cos(a1)*radius, z+math.sin(a1)*radius,
			x, y+math.cos(a2)*radius, z+math.sin(a2)*radius, col, 2)
	end
end

-- FIX: Clear cache when element is destroyed
addEventHandler("onClientElementDestroy", root, function()
	if getElementType(source) == "ped" then
		lastValidDebug[source] = nil
	end
end)