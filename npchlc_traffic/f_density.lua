local traffic_auto_mode = true

function isTrafficAutoMode()
	return traffic_auto_mode
end

function setTrafficAutoMode(state)
	traffic_auto_mode = state
	if state then
		outputChatBox("Traffic Density: AUTO MODE ENABLED", root, 0, 255, 0)
		-- Trigger immediate check? handled by timer next tick
	else
		outputChatBox("Traffic Density: MANUAL MODE (Auto disabled)", root, 255, 150, 0)
	end
end

function setTrafficDensity(trtype,density, isAutoCall)
	-- If manual call (isAutoCall is nil/false), disable auto mode
	if not isAutoCall then
		if traffic_auto_mode then
			setTrafficAutoMode(false)
		end
	end

	density = tonumber(density)
	if density then
		density = density*0.01
		if traffic_density[trtype] then
			traffic_density[trtype] = density
			-- ADDED: Force immediate traffic update
			-- Only notify if manual or significant change?
			
			if not isAutoCall then
				setTimer(function()
					updateTraffic()
					outputChatBox("Density of " .. trtype .. " changed to " .. (density*100) .. "%", root)
				end, 100, 1)
			else
				-- Silent update for auto
				updateTraffic()
			end
			return true
		end
	else
		density = tonumber(trtype)
		if density then
			density = density*0.01
			for trtype in pairs(traffic_density) do
				traffic_density[trtype] = density
			end
			-- ADDED: Force immediate traffic update
			if not isAutoCall then
				setTimer(function()
					updateTraffic()
					outputChatBox("General density changed to " .. (density*100) .. "%", root)
				end, 100, 1)
			else
				updateTraffic()
			end
			return true
		end
	end
	return false
end

function getTrafficDensity(trtype)
	return trtype and traffic_density[trtype] or false
end

-- ADDED: Function to force immediate traffic update
function forceTrafficUpdate()
    if updateTraffic then
        updateTraffic()
        outputChatBox("Traffic updated manually!", root)
    else
        outputChatBox("Traffic system not initialized!", root)
    end
end

-- ADDED: Command to test manual update
addCommandHandler("updatetraffic", forceTrafficUpdate)

-- ADDED: Command to spawn traffic instantly around player
addCommandHandler("spawntraffic", function(player)
    if not square_id or not spawnTrafficInSquare then
        outputChatBox("Traffic system not initialized!", player)
        return
    end
    
    local x, y = getElementPosition(player)
    local dim = getElementDimension(player)
    x, y = math.floor(x/SQUARE_SIZE), math.floor(y/SQUARE_SIZE)
    
    local spawned = 0
    -- Force spawn in 3x3 squares around player
    for sy = y-1, y+1 do
        for sx = x-1, x+1 do
            -- Check if square exists
            if square_id[sy] and square_id[sy][sx] then
                spawnTrafficInSquare(sx, sy, dim, "cars")
                spawned = spawned + 1
            end
        end
    end
    
    outputChatBox("Spawn attempt in " .. spawned .. " squares around!", player)
end)

-- ADDED: Command to clear all traffic
addCommandHandler("cleartraffic", function(player)
    local cleared_cars = 0
    local cleared_peds = 0
    
    if population and population.cars then
        for car, exists in pairs(population.cars) do
            if isElement(car) then
                destroyElement(car)
                cleared_cars = cleared_cars + 1
            end
        end
    end
    
    if population and population.peds then
        for ped, exists in pairs(population.peds) do
            if isElement(ped) and not isPedInVehicle(ped) then
                destroyElement(ped)
                cleared_peds = cleared_peds + 1
            end
        end
    end
    
    -- Clear the tables
    if population then
        population.cars = {}
        population.peds = {}
    end
    
    -- Clear trailer connections
    if trailer_connections then
        trailer_connections = {}
    end
    
    outputChatBox("Traffic cleared! Cars: " .. cleared_cars .. ", Peds: " .. cleared_peds, player)
end)

-- ADDED: Command to see traffic status
addCommandHandler("trafficstatus", function(player)
    if not traffic_density then
        outputChatBox("Traffic system not initialized!", player)
        return
    end
    
    local car_count = 0
    local ped_count = 0
    local trailer_count = 0
    
    if population then
        if population.cars then
            for car, exists in pairs(population.cars) do
                if isElement(car) then
                    car_count = car_count + 1
                end
            end
        end
        
        if population.peds then
            for ped, exists in pairs(population.peds) do
                if isElement(ped) then
                    ped_count = ped_count + 1
                end
            end
        end
    end
    
    if trailer_connections then
        for truck, trailer in pairs(trailer_connections) do
            if isElement(truck) and isElement(trailer) then
                trailer_count = trailer_count + 1
            end
        end
    end
    
    outputChatBox("=== TRAFFIC STATUS ===", player)
    outputChatBox("Active cars: " .. car_count, player)
    outputChatBox("Active peds: " .. ped_count, player)
    outputChatBox("Hitched trailers: " .. trailer_count, player)
    outputChatBox("Car density: " .. (traffic_density.cars * 100) .. "%", player)
    outputChatBox("Ped density: " .. (traffic_density.peds * 100) .. "%", player)
end)