function initAI()
	ped_nodes = {}
	ped_conns = {}
	ped_thisnode = {}
	ped_lastnode = {}
	ped_lane = {}
	ped_drivespeed = {}
end

function initPedRouteData(ped)
	if not isElement(ped) then return end -- Extra protection
	ped_nodes[ped] = {}
	ped_conns[ped] = {}
	ped_drivespeed[ped] = {}
	addEventHandler("onElementDestroy",ped,uninitPedRouteDataOnDestroy)
	addEventHandler("npc_hlc:onNPCTaskDone",ped,continuePedRoute)
end

function uninitPedRouteDataOnDestroy()
	ped_nodes[source] = nil
	ped_conns[source] = nil
	ped_thisnode[source] = nil
	ped_lastnode[source] = nil
	ped_lane[source] = nil
	ped_drivespeed[source] = nil
end

function continuePedRoute(task)
	if not isElement(source) then return end -- Protection
	if task[1] == "waitForGreenLight" then return end
	
	-- IMPORTANT: Don't continue route if ped is in combat mode (chasing/attacking player)
	if getElementData(source, "ped.combat_mode") then return end
	
	local thisnode = ped_thisnode[source]
	if not thisnode or not ped_drivespeed[source] then return end -- Null data protection

	-- Move to next node first
	local nextnode = thisnode + 1
	ped_thisnode[source] = nextnode
	
	-- Check if next segment has a different speed
	local speed = ped_drivespeed[source][nextnode]
	if speed then
		-- Apply speed personality modifier if exists
		local personality = getElementData(source, "npc.speedPersonality") or 1.0
		local adjustedSpeed = (speed/180) * personality
		
		-- Save BASE route speed for Speed Governor
		call(npc_hlc, "saveBaseSpeed", source, adjustedSpeed)
		call(npc_hlc, "setNPCDriveSpeed", source, adjustedSpeed)
		ped_drivespeed[source][nextnode] = nil
	end
	
	-- NEW: Analyze upcoming turn before continuing
	local vehicle = getPedOccupiedVehicle(source)
	if vehicle and isElement(vehicle) then
		analyzeUpcomingTurn(source, vehicle)
	end
	
	addRandomNodeToPedRoute(source)
end

-- Event handler to resume route after combat ends
addEvent("npc_hlc:resumeRoute", false)
addEventHandler("npc_hlc:resumeRoute", root, function()
	local ped = source
	if not isElement(ped) then return end
	if isPedInVehicle(ped) then return end -- Only for pedestrians on foot
	
	-- Check if route data still exists
	if ped_lastnode[ped] and ped_nodes[ped] then
		-- Route data exists, just continue normally
		addRandomNodeToPedRoute(ped)
	else
		-- Route data was lost, find nearest node and reinitialize
		local px, py, pz = getElementPosition(ped)
		local nearestNode = nil
		local nearestDist = 9999
		
		-- Find nearest node
		if node_x and node_y then
			for nodeId, x in pairs(node_x) do
				local y = node_y[nodeId]
				if y then
					local dist = getDistanceBetweenPoints2D(px, py, x, y)
					if dist < nearestDist then
						nearestDist = dist
						nearestNode = nodeId
					end
				end
			end
		end
		
		if nearestNode then
			-- Reinitialize route data for this ped
			if not ped_nodes[ped] then ped_nodes[ped] = {} end
			if not ped_conns[ped] then ped_conns[ped] = {} end
			if not ped_drivespeed[ped] then ped_drivespeed[ped] = {} end
			
			ped_nodes[ped][1] = nearestNode
			ped_lastnode[ped] = 1
			ped_thisnode[ped] = 1
			ped_lane[ped] = 0
			
			-- Add next random node to start walking
			addRandomNodeToPedRoute(ped)
		end
	end
end)

function addNodeToPedRoute(ped,nodeid,nb)
	if not isElement(ped) then return end -- Vital Correction

	local n1num = ped_lastnode[ped]
	if not n1num then
		ped_nodes[ped][1] = nodeid
		ped_lastnode[ped] = 1
		return
	end
	
	local n0num,n2num = n1num-1,n1num+1
	local prevnode = ped_nodes[ped][n1num]
	
	-- Protection: Check if nodes exist
	if not prevnode or not node_conns[prevnode] or not node_conns[prevnode][nodeid] then
		return 
	end

	local connid = node_conns[prevnode][nodeid]
	local lane = ped_lane[ped]
	ped_nodes[ped][n2num] = nodeid
	ped_conns[ped][n2num] = connid

	local n0 = ped_nodes[ped][n0num]
	local speed = conn_maxspeed[connid]
	
	-- FIXED: Check if speed changes between connections
	-- Always update drive speed when transitioning to a new connection with different speed
	if n0 and node_conns[n0] and node_conns[n0][prevnode] then
		local prevConnId = node_conns[n0][prevnode]
		local prevSpeed = conn_maxspeed[prevConnId]
		if prevSpeed and speed and prevSpeed ~= speed then
			-- Speed change detected - schedule update for when NPC reaches this node
			ped_drivespeed[ped][n2num] = speed
		end
	else
		-- No previous connection data, set speed for this segment
		ped_drivespeed[ped][n2num] = speed
	end

	local x1,y1,z1 = getNodeConnLanePos(prevnode,connid,lane,false)
	local x2,y2,z2 = getNodeConnLanePos(nodeid,connid,lane,true)

	local zoff
	local vehicle = getPedOccupiedVehicle(ped)
	
	-- BUG FIX: Check element before getting model
	local targetElement = vehicle or ped
	if not isElement(targetElement) then return end
	local model = getElementModel(targetElement)
	
	if vehicle then
		local dx,dy,dz = x2-x1,y2-y1,z2-z1
		dx,dy,dz = dx*dx,dy*dy,dz*dz
		local dist = math.sqrt(dx+dy+dz)
		if dist > 0 then
			zoff = (z_offset[model] or 1)*math.sqrt((dx+dy)/(dx+dy+dz)) -- nil z_offset protection
		else
			zoff = 1
		end
	else
		zoff = 1
	end

	z1,z2 = z1+zoff,z2+zoff

	local lights
	if nodeid == conn_n1[connid] then
		lights = conn_light1[connid]
	else
		lights = conn_light2[connid]
	end

	if vehicle then
		local off = speed*0.1
		-- Protection for external call
		local boxY2 = 5
		if server_coldata then
			local succ, res = pcall(call, server_coldata,"getModelBoundingBox",model,"y2")
			if succ and res then boxY2 = res end
		end
		
		local enddist = lights and boxY2+5 or off
		if nb then
			call(npc_hlc,"addNPCTask",ped,{"driveAroundBend",node_x[nb],node_y[nb],x1,y1,z1,x2,y2,z2,off,enddist})
		else
			call(npc_hlc,"addNPCTask",ped,{"driveAlongLine",x1,y1,z1,x2,y2,z2,off,enddist})
		end
	else
		if nb then
			call(npc_hlc,"addNPCTask",ped,{"walkAroundBend",node_x[nb],node_y[nb],x1,y1,z1,x2,y2,z2,1,1})
		else
			call(npc_hlc,"addNPCTask",ped,{"walkAlongLine",x1,y1,z1,x2,y2,z2,1,1})
		end
	end
	if not ped_thisnode[ped] then ped_thisnode[ped] = 1 end
	ped_lastnode[ped] = n2num

	if lights then
		call(npc_hlc,"addNPCTask",ped,{"waitForGreenLight",lights})
	end
end

function addRandomNodeToPedRoute(ped)
	if not isElement(ped) or not ped_lastnode[ped] then return end -- Proteção

	local n2num = ped_lastnode[ped]
	local n1num,n3num = n2num-1,n2num+1
	local n1,n2 = ped_nodes[ped][n1num],ped_nodes[ped][n2num]
	
	if not n1 or not n2 or not node_conns[n1] or not node_conns[n2] then return end

	local possible_turns = {}
	local total_density = 0
	local c12 = node_conns[n1][n2]
	
	if not c12 then return end

	for n3,connid in pairs(node_conns[n2]) do
		local c23 = node_conns[n2][n3]
		if c23 and not conn_forbidden[c12][c23] then
			if conn_lanes.left[connid] == 0 and conn_lanes.right[connid] == 0 then
				if n3 ~= n1 then
					local density = conn_density[connid]
					total_density = total_density+density
					table.insert(possible_turns,{n3,connid,density})
				end
			else
				local dirmatch1 = areDirectionsMatching(n2,n1,n2)
				local dirmatch2 = areDirectionsMatching(n2,n2,n3)
				if dirmatch1 == dirmatch2 then
					local density = conn_density[connid]
					total_density = total_density+density
					table.insert(possible_turns,{n3,connid,density})
				end
			end
		end
	end
	local n3,connid
	local possible_count = #possible_turns
	if possible_count == 0 then
		n3,connid = next(node_conns[n2])
	else
		local pos = math.random()*total_density
		local num = 1
		while true do
			num = num%possible_count+1
			local turn = possible_turns[num]
			pos = pos-turn[3]
			if pos <= 0 then
				n3,connid = turn[1],turn[2]
				break
			end
		end
	end
	if n3 then
		addNodeToPedRoute(ped,n3,conn_nb[connid])
	end
end

-- Kept angle/arrow functions same as they seem safe if calls above are protected
local function calculateTurnAngle(x1, y1, x2, y2, x3, y3)
	local vec1_x, vec1_y = x2 - x1, y2 - y1
	local vec2_x, vec2_y = x3 - x2, y3 - y2
	
	local len1 = math.sqrt(vec1_x^2 + vec1_y^2)
	local len2 = math.sqrt(vec2_x^2 + vec2_y^2)
	
	if len1 == 0 or len2 == 0 then return 0, 0 end
	
	vec1_x, vec1_y = vec1_x / len1, vec1_y / len1
	vec2_x, vec2_y = vec2_x / len2, vec2_y / len2
	
	local cross = vec1_x * vec2_y - vec1_y * vec2_x
	local dot = vec1_x * vec2_x + vec1_y * vec2_y
	local angle = math.acos(math.max(-1, math.min(1, dot)))
	
	return math.deg(angle), cross
end

function analyzeUpcomingTurn(ped, vehicle)
	if not ped_nodes[ped] or not ped_thisnode[ped] then return end
	
	local currentNode = ped_thisnode[ped]
	local nextNode = currentNode + 1
	local futureNode = currentNode + 2
	
	if not ped_nodes[ped][currentNode] or not ped_nodes[ped][nextNode] or not ped_nodes[ped][futureNode] then
		return
	end
	
	local node1 = ped_nodes[ped][currentNode]
	local node2 = ped_nodes[ped][nextNode] 
	local node3 = ped_nodes[ped][futureNode]
	
	local x1, y1 = node_x[node1], node_y[node1]
	local x2, y2 = node_x[node2], node_y[node2]
	local x3, y3 = node_x[node3], node_y[node3]
	
	if not x1 or not y1 or not x2 or not y2 or not x3 or not y3 then return end
	
	local angle, cross = calculateTurnAngle(x1, y1, x2, y2, x3, y3)
	
	if angle > 20 then
		-- Use table or safe check to avoid excessive setElementData if already set
		-- cross < 0 = turn left, cross > 0 = turn right
		if getElementData(vehicle, "turn_left") ~= (cross < 0) then
			setElementData(vehicle, "turn_left", cross < 0)
			setElementData(vehicle, "turn_right", cross >= 0)
			setElementData(vehicle, "emergency_light", false)
			
			setTimer(function()
				if isElement(vehicle) then
					setElementData(vehicle, "turn_left", false)
					setElementData(vehicle, "turn_right", false)
				end
			end, 4000, 1)
		end
	end
end