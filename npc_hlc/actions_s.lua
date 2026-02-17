function makeNPCWalkToPos(npc,x,y,z,maxtime)
	local px,py,pz = getElementPosition(npc)
	local walk_dist = NPC_SPEED_ONFOOT[getNPCWalkSpeed(npc)]*maxtime*0.001
	local dx,dy,dz = x-px,y-py,z-pz
	local dist = getDistanceBetweenPoints3D(0,0,0,dx,dy,dz)
	dx,dy,dz = dx/dist,dy/dist,dz/dist
	local maxtime_unm = maxtime
	if dist < walk_dist then
		maxtime = maxtime*dist/walk_dist
		walk_dist = dist
	end
	local model = getElementModel(npc)
	x,y,z = px+dx*walk_dist,py+dy*walk_dist,pz+dz*walk_dist
	local rot = -math.deg(math.atan2(dx,dy))

	local move = true
	if check_cols then
		local box = call(server_coldata,"createModelIntersectionBox",model,x,y,z,rot)
		local boxprev = call(server_coldata,"getElementIntersectionBox",npc)
		move = not call(server_coldata,"doesModelBoxIntersect",box,getElementDimension(npc),boxprev)
	end
	if move then
		setElementPosition(npc,x,y,z,false)
		setPedRotation(npc,rot)
		if check_cols then call(server_coldata,"updateElementColData",npc) end
		return maxtime
	else
		setElementPosition(npc,px,py,pz)
		setPedRotation(npc,getPedRotation(npc))
		return maxtime_unm
	end
end

function makeNPCWalkAlongLine(npc,x1,y1,z1,x2,y2,z2,off,maxtime)
	local x_this,y_this,z_this = getElementPosition(npc)
	local walk_dist = NPC_SPEED_ONFOOT[getNPCWalkSpeed(npc)]*maxtime*0.001
	local p2_this = getPercentageInLine(x_this,y_this,x1,y1,x2,y2)
	local p1_this = 1-p2_this
	local len = getDistanceBetweenPoints3D(x1,y1,z1,x2,y2,z2)
	local p2_next = p2_this+walk_dist/len
	local p1_next = 1-p2_next
	local x_next,y_next,z_next
	local maxtime_unm = maxtime
	if p2_next > 1 then
		maxtime = maxtime*(1-p2_this)/(p2_next-p2_this)
		x_next,y_next,z_next = x2,y2,z2
	else
		x_next = x1*p1_next+x2*p2_next
		y_next = y1*p1_next+y2*p2_next
		z_next = z1*p1_next+z2*p2_next
	end
	local model = getElementModel(npc)
	local rot = -math.deg(math.atan2(x2-x1,y2-y1))

	local move = true
	if check_cols then
		local box = call(server_coldata,"createModelIntersectionBox",model,x_next,y_next,z_next,rot)
		local boxprev = call(server_coldata,"getElementIntersectionBox",npc)
		move = not call(server_coldata,"doesModelBoxIntersect",box,getElementDimension(npc),boxprev)
	end
	if move then
		setElementPosition(npc,x_next,y_next,z_next,false)
		setPedRotation(npc,rot)
		if check_cols then call(server_coldata,"updateElementColData",npc) end
		return maxtime
	else
		setElementPosition(npc,x_this,y_this,z_this)
		setPedRotation(npc,getPedRotation(npc))
		return maxtime_unm
	end
end

function makeNPCWalkAroundBend(npc,x0,y0,x1,y1,z1,x2,y2,z2,off,maxtime)
	local x_this,y_this,z_this = getElementPosition(npc)
	local walk_dist = NPC_SPEED_ONFOOT[getNPCWalkSpeed(npc)]*maxtime*0.001
	local p2_this = getAngleInBend(x_this,y_this,x0,y0,x1,y1,x2,y2)/math.pi*2
	local p1_this = 1-p2_this
	local len = getDistanceBetweenPoints3D(x1,y1,z1,x2,y2,z2)
	local p2_next = p2_this+walk_dist/len
	local p1_next = 1-p2_next
	local x_next,y_next,z_next,a_next
	local maxtime_unm = maxtime
	if p2_next > 1 then
		maxtime = maxtime*(1-p2_this)/(p2_next-p2_this)
		x_next,y_next,z_next = x2,y2,z2
		a_next = -math.deg(math.atan2(x0-x1,y0-y1))
	else
		x_next,y_next = getPosFromBend(p2_next*math.pi*0.5,x0,y0,x1,y1,x2,y2)
		z_next = z1*p1_next+z2*p2_next
		local x_next_front,y_next_front = getPosFromBend(p2_next*math.pi*0.5+0.01,x0,y0,x1,y1,x2,y2)
		a_next = -math.deg(math.atan2(x_next_front-x_next,y_next_front-y_next))
	end
	local model = getElementModel(npc)

	local move = true
	if check_cols then
		local box = call(server_coldata,"createModelIntersectionBox",model,x_next,y_next,z_next,a_next)
		local boxprev = call(server_coldata,"getElementIntersectionBox",npc)
		move = not call(server_coldata,"doesModelBoxIntersect",box,getElementDimension(npc),boxprev)
	end
	if move then
		setElementPosition(npc,x_next,y_next,z_next,false)
		setPedRotation(npc,a_next)
		if check_cols then call(server_coldata,"updateElementColData",npc) end
		return maxtime
	else
		setElementPosition(npc,x_this,y_this,z_this)
		setPedRotation(npc,getPedRotation(npc))
		return maxtime_unm
	end
end

function checkTaskLookahead(npc, distRemaining, currentSpeed)
	local this_task = getElementData(npc, "npc_hlc:this_task")
	if not this_task then return 1.0 end
	
	local next_task = getElementData(npc, "npc_hlc:task."..(this_task+1))
	if not next_task then return 1.0 end
	
	-- 1. TURN ANTICIPATION (Cornering Physics)
	if next_task[1] == "driveAroundBend" then
		-- Calculate Radius of upcoming bend
		local x0, y0 = next_task[2], next_task[3] -- Center
		local x1, y1 = next_task[4], next_task[5] -- Start
		
		local radius = getDistanceBetweenPoints2D(x0, y0, x1, y1)
		local safeEntrySpeed = math.sqrt(12.0 * radius) -- v = sqrt(friction * R)
		
		if currentSpeed > safeEntrySpeed then
			-- Calculate braking distance needed to reduce from v_curr to v_safe
			-- d = (v_curr^2 - v_safe^2) / 2a
			local veh = getPedOccupiedVehicle(npc) or npc
			local decel, _ = getVehiclePhysicsProfile(veh)
			
			local reqInfoDist = (currentSpeed^2 - safeEntrySpeed^2) / (2 * (decel * 0.8))
			
			if distRemaining < (reqInfoDist + 20.0) then
				-- Ramp down factor
				-- Target speed map:
				-- @reqDist: currentSpeed
				-- @0: safeEntrySpeed
				local factor = safeEntrySpeed / currentSpeed
				local distFactor = math.max(0.0, (distRemaining / (reqInfoDist + 5.0)))
				
				-- Blend
				return math.min(1.0, factor + (1.0 - factor) * distFactor)
			end
		end
	end
	
	-- 2. TRAFFIC LIGHT ANTICIPATION
	if next_task[1] == "waitForGreenLight" then
		local state = getTrafficLightState()
		local dir = next_task[2]
		
		local blocked = false
		if state == 6 or state == 9 then blocked = true end
		if dir == "NS" and (state == 0 or state == 5 or state == 8) then blocked = true end
		if dir == "WE" and (state == 3 or state == 5 or state == 7) then blocked = true end
		if dir == "ped" and state == 2 then blocked = true end
		
		if blocked then
			-- Physics Stop
			local veh = getPedOccupiedVehicle(npc) or npc
			local decel, _ = getVehiclePhysicsProfile(veh)
			
			-- Required Stopping Distance: v^2 / 2a
			-- Use slightly lower decel for smooth stop
			local reqDist = (currentSpeed * currentSpeed) / (2 * (decel * 0.7)) 
			
			if distRemaining < (reqDist + 20.0) then
				if distRemaining < 5.0 then return 0.0 end -- Emergency Stop
				
				local factor = (distRemaining - 5.0) / reqDist
				return math.max(0.0, math.min(1.0, factor))
			end
			
			-- Early Coasting
			if distRemaining < 120.0 and currentSpeed > 20.0 then
				return 0.5 
			end
		end
	end
	return 1.0
end

function makeNPCDriveToPos(npc,x,y,z,maxtime)
	local car = getPedOccupiedVehicle(npc)
	local px,py,pz = getElementPosition(car)
	local speed = getNPCDriveSpeed(npc)
	-- SENSOR & LOGIC
	-- getSurroundingThreats with Gaze Control (looks at destination x,y)
	local threats, currentSpeed = getSurroundingThreats(npc, x, y)
	local brakeFactor = calculateBrakingFactor(threats, currentSpeed, npc)
	
	-- Intersection Logic
	if getIntersectionState then
		local yieldState = getIntersectionState(npc)
		if yieldState == "yield" then
			brakeFactor = 0.2 -- Yield to cross traffic (Creep Mode)
		end
	end
	
	speed = speed * brakeFactor
	
	-- DEBUG UPDATE
	if getElementData(npc, "debug.sensor") then
		local d = getElementData(npc, "debug.sensor")
		d.brake = brakeFactor
		setElementData(npc, "debug.sensor", d)
	end
	-- END SENSOR LOGIC
	local drive_dist = speed*50*maxtime*0.001
	local dx,dy,dz = x-px,y-py,z-pz
	local dist = getDistanceBetweenPoints3D(0,0,0,dx,dy,dz)
	dx,dy,dz = dx/dist,dy/dist,dz/dist
	local rx,ry,rz = math.deg(math.asin(dz)),0,-math.deg(math.atan2(dx,dy))
	local vx,vy,vx
	local maxtime_unm = maxtime
	if dist < drive_dist then
		maxtime = maxtime*dist/drive_dist
		drive_dist = dist
		vx,vy,vz = 0,0,0
	else
		vx,vy,vz = dx*speed,dy*speed,dz*speed
	end
	local model = getElementModel(car)
	x,y,z = px+dx*drive_dist,py+dy*drive_dist,pz+dz*drive_dist

	local move = true
	if check_cols then
		local box = call(server_coldata,"createModelIntersectionBox",model,x,y,z,rz)
		local boxprev = call(server_coldata,"getElementIntersectionBox",car)
		move = not call(server_coldata,"doesModelBoxIntersect",box,getElementDimension(car),boxprev)
	end
	
	if move then
		setElementPosition(car,x,y,z,true)
		setElementRotation(car,rx,ry,rz)
		setElementVelocity(car,vx,vy,vz)
		setVehicleTurnVelocity(car,0,0,0)
		setElementPosition(npc,x,y,z)
		if check_cols then call(server_coldata,"updateElementColData",car) end
		return maxtime
	else
		setElementPosition(car,px,py,pz,true)
		setElementRotation(car,getElementRotation(car))
		setElementVelocity(car,0,0,0)
		setVehicleTurnVelocity(car,0,0,0)
		return maxtime_unm
	end
end

function makeNPCDriveAlongLine(npc,x1,y1,z1,x2,y2,z2,off,maxtime)
	local car = getPedOccupiedVehicle(npc)
	local x_this,y_this,z_this = getElementPosition(car)
	local speed = getNPCDriveSpeed(npc)
	
	-- CALC GEOMETRY EARLY
	local len = getDistanceBetweenPoints3D(x1,y1,z1,x2,y2,z2)
	local p2_this = getPercentageInLine(x_this,y_this,x1,y1,x2,y2)
	local distRemaining = len * (1 - p2_this)
	
	-- SENSOR & LOGIC
	-- getSurroundingThreats with Gaze Control (looks at destination x2,y2)
	local threats, currentSpeed = getSurroundingThreats(npc, x2, y2)
	local brakeFactor = calculateBrakingFactor(threats, currentSpeed, npc)
	
	-- Intersection Logic
	if getIntersectionState then
		local yieldState = getIntersectionState(npc)
		if yieldState == "yield" then
			brakeFactor = 0.0 -- Yield to cross traffic (STOP completely)
		end
	end
	
	-- Traffic Light & Corner Logic (Lookahead)
	local aheadFactor = checkTaskLookahead(npc, distRemaining, currentSpeed)

	speed = speed * brakeFactor * aheadFactor
	
	-- DEBUG UPDATE
	if getElementData(npc, "debug.sensor") then
		local d = getElementData(npc, "debug.sensor")
		d.brake = brakeFactor * aheadFactor
		d.lookahead = aheadFactor
		setElementData(npc, "debug.sensor", d)
	end
	-- END SENSOR LOGIC
	local drive_dist = speed*50*maxtime*0.001
	
	-- p2_this already calculated
	local p1_this = 1-p2_this
	-- len already calculated
	local p2_next = p2_this+drive_dist/len
	local p1_next = 1-p2_next
	local x_next,y_next,z_next
	local dirx,diry,dirz = (x2-x1)/len,(y2-y1)/len,(z2-z1)/len
	local vx,vy,vz
	local maxtime_unm = maxtime
	if p2_next > 1 then
		maxtime = maxtime*(1-p2_this)/(p2_next-p2_this)
		x_next,y_next,z_next = x2,y2,z2
		vx,vy,vz = 0,0,0
	else
		x_next = x1*p1_next+x2*p2_next
		y_next = y1*p1_next+y2*p2_next
		z_next = z1*p1_next+z2*p2_next
		vx,vy,vz = dirx*speed,diry*speed,dirz*speed
	end
	local model = getElementModel(car)
	local rx,ry,rz = math.deg(math.asin(dirz)),0,-math.deg(math.atan2(dirx,diry))

	local move = true
	if check_cols then
		local box = call(server_coldata,"createModelIntersectionBox",model,x_next,y_next,z_next,rz)
		local boxprev = call(server_coldata,"getElementIntersectionBox",car)
		move = not call(server_coldata,"doesModelBoxIntersect",box,getElementDimension(car),boxprev)
	end
	
	if move then
		setElementPosition(car,x_next,y_next,z_next,true)
		setElementRotation(car,rx,ry,rz)
		setElementVelocity(car,vx,vy,vz)
		setVehicleTurnVelocity(car,0,0,0)
		setElementPosition(npc,x_next,y_next,z_next)
		if check_cols then call(server_coldata,"updateElementColData",car) end
		return maxtime
	else
		setElementPosition(car,x_this,y_this,z_this,true)
		setElementRotation(car,getElementRotation(car))
		setElementVelocity(car,0,0,0)
		setVehicleTurnVelocity(car,0,0,0)
		return maxtime_unm
	end
end

function makeNPCDriveAroundBend(npc,x0,y0,x1,y1,z1,x2,y2,z2,off,maxtime)
	local car = getPedOccupiedVehicle(npc)
	local x_this,y_this,z_this = getElementPosition(car)
	local speed = getNPCDriveSpeed(npc)
	
	-- CALC GEOMETRY EARLY
	local len = getDistanceBetweenPoints3D(x1,y1,z1,x2,y2,z2)*math.pi*0.5
	local p2_this = getAngleInBend(x_this,y_this,x0,y0,x1,y1,x2,y2)/math.pi*2
	local distRemaining = len * (1 - p2_this)
	
	-- SENSOR & LOGIC
	-- SENSOR & LOGIC
	-- getSurroundingThreats with Gaze Control + ARC DETECTION
	-- Pass Bend Data (Center x0,y0)
	local bendRadius = getDistanceBetweenPoints2D(x0,y0, x1,y1)
	local bendData = {cx=x0, cy=y0, radius=bendRadius, ex=x2, ey=y2}
	
	local threats, currentSpeed = getSurroundingThreats(npc, x2, y2, bendData)
	local brakeFactor = calculateBrakingFactor(threats, currentSpeed, npc)
	
	-- Intersection Logic
	if getIntersectionState then
		local yieldState = getIntersectionState(npc)
		if yieldState == "yield" then
			brakeFactor = 0.0 -- Yield to cross traffic (STOP completely)
		end
	end
	
	-- Lookahead for Next Task
	local aheadFactor = checkTaskLookahead(npc, distRemaining, currentSpeed)
	
	-- Internal Curve Speed Limit (Centripetal Force)
	local radius = getDistanceBetweenPoints2D(x0,y0, x1,y1)
	local maxCurveSpeed = math.sqrt(15.0 * radius) -- 15.0 for grip
	if speed > maxCurveSpeed then
		speed = maxCurveSpeed
	end

	speed = speed * brakeFactor * aheadFactor
	
	-- DEBUG UPDATE
	if getElementData(npc, "debug.sensor") then
		local d = getElementData(npc, "debug.sensor")
		d.brake = brakeFactor * aheadFactor
		d.lookahead = aheadFactor
		setElementData(npc, "debug.sensor", d)
	end
	-- END SENSOR LOGIC
	local drive_dist = speed*50*maxtime*0.001
	local p2_this = getAngleInBend(x_this,y_this,x0,y0,x1,y1,x2,y2)/math.pi*2
	local p1_this = 1-p2_this
	local len = getDistanceBetweenPoints3D(x1,y1,z1,x2,y2,z2)
	local p2_next = p2_this+drive_dist/len
	local p1_next = 1-p2_next
	local x_next,y_next,z_next
	local dirx,diry,dirz,vx,vy,vz
	local maxtime_unm = maxtime
	if p2_next > 1 then
		maxtime = maxtime*(1-p2_this)/(p2_next-p2_this)
		x_next,y_next,z_next = x2,y2,z2
		dirx,diry,dirz = x1-x0,y1-y0,z1-z2
		local dirlen = 1/getDistanceBetweenPoints3D(0,0,0,dirx,diry,dirz)
		dirx,diry,dirz = dirx*dirlen,diry*dirlen,dirz*dirlen
		vx,vy,vz = 0,0,0
	else
		x_next,y_next = getPosFromBend(p2_next*math.pi*0.5,x0,y0,x1,y1,x2,y2)
		z_next = z1*p1_next+z2*p2_next
		local x_next_front,y_next_front = getPosFromBend(p2_next*math.pi*0.5+0.01,x0,y0,x1,y1,x2,y2)
		local z_next_front = z1*(p1_next-0.01)+z2*(p2_next+0.01)

		dirx,diry,dirz = x_next_front-x_next,y_next_front-y_next,z_next_front-z_next
		local dirlen = 1/getDistanceBetweenPoints3D(0,0,0,dirx,diry,dirz)
		dirx,diry,dirz = dirx*dirlen,diry*dirlen,dirz*dirlen
		vx,vy,vz = dirx*speed,diry*speed,dirz*speed
	end
	local model = getElementModel(car)
	local rx,ry,rz = math.deg(math.asin(dirz)),0,-math.deg(math.atan2(dirx,diry))

	local move = true
	if check_cols then
		local box = call(server_coldata,"createModelIntersectionBox",model,x_next,y_next,z_next,rz)
		local boxprev = call(server_coldata,"getElementIntersectionBox",car)
		move = not call(server_coldata,"doesModelBoxIntersect",box,getElementDimension(car),boxprev)
	end
	
	if move then
		setElementPosition(car,x_next,y_next,z_next,true)
		setElementRotation(car,rx,ry,rz)
		setElementVelocity(car,vx,vy,vz)
		setVehicleTurnVelocity(car,0,0,0)
		setElementPosition(npc,x_next,y_next,z_next)
		if check_cols then call(server_coldata,"updateElementColData",car) end
		return maxtime
	else
		setElementPosition(car,x_this,y_this,z_this,true)
		setElementRotation(car,getElementRotation(car))
		setElementVelocity(car,0,0,0)
		setVehicleTurnVelocity(car,0,0,0)
		return maxtime_unm
	end
end

