-- =============================================================================
-- NPC CONTROL (CLIENT-SIDE) - OPTIMIZED v2.1
-- KEPT: onClientPreRender for smooth NPC steering (frame-accurate)
-- ADDED: Streamed NPC cache to avoid getElementsByType
-- ADDED: Local task cache to avoid getElementData per NPC per frame
-- =============================================================================

UPDATE_INTERVAL_MS = 50

-- Global NPC cache — event-driven, avoids getElementsByType
local streamed_npcs = {}
-- Local task cache — avoids getElementData("npc_hlc:thistask") every frame
local task_cache = {}

function initNPCControl()
	-- Keep onClientPreRender for frame-accurate steering
	addEventHandler("onClientPreRender", root, cycleNPCs)
	
	-- Event-driven cache management
	addEventHandler("onClientElementStreamIn", root, cacheNPC)
	addEventHandler("onClientElementStreamOut", root, uncacheNPC)
	addEventHandler("onClientElementDestroy", root, uncacheNPC)
	
	-- Track task changes from server to keep local cache in sync
	addEventHandler("onClientElementDataChange", root, onTaskDataChange)
	
	-- Populate initial cache
	for i, ped in ipairs(getElementsByType("ped", root, true)) do
		if getElementData(ped, "npc_hlc") then
			streamed_npcs[ped] = true
			task_cache[ped] = getElementData(ped, "npc_hlc:thistask")
		end
	end
end

function cacheNPC()
	if getElementType(source) == "ped" and getElementData(source, "npc_hlc") then
		streamed_npcs[source] = true
		task_cache[source] = getElementData(source, "npc_hlc:thistask")
		
		-- ANTI-WARP: Hide "pop-in" teleport, fade in smoothly
		setElementAlpha(source, 0)
		local vehicle = getPedOccupiedVehicle(source)
		if vehicle then setElementAlpha(vehicle, 0) end
		
		local progress = 0
		setTimer(function(ped, veh)
			progress = progress + 0.1
			local alpha = math.min(255, progress * 255)
			if isElement(ped) then setElementAlpha(ped, alpha) end
			if isElement(veh) then setElementAlpha(veh, alpha) end
		end, 150, 10, source, vehicle)
	end
end

function uncacheNPC()
	if streamed_npcs[source] then
		streamed_npcs[source] = nil
		task_cache[source] = nil
	end
end

-- Keep local task cache in sync with server changes
function onTaskDataChange(key, oldVal, newVal)
	if key == "npc_hlc:thistask" and streamed_npcs[source] then
		task_cache[source] = newVal
	end
end

function cycleNPCs()
	-- Process ALL streamed NPCs every frame (required for smooth steering)
	for npc, _ in pairs(streamed_npcs) do
		if not isElement(npc) then
			streamed_npcs[npc] = nil
			task_cache[npc] = nil
		elseif getElementHealth(getPedOccupiedVehicle(npc) or npc) >= 1 then
			while true do
				-- Use cached task index instead of getElementData
				local thistask = task_cache[npc]
				if thistask then
					local task = getElementData(npc, "npc_hlc:task."..thistask)
					if task then
						if performTask[task[1]](npc, task) then
							setNPCTaskToNext(npc)
						else
							break
						end
					else
						stopAllNPCActions(npc)
						break
					end
				else
					stopAllNPCActions(npc)
					break
				end
			end
		else
			stopAllNPCActions(npc)
		end
	end
end

function setNPCTaskToNext(npc)
	local current = task_cache[npc]
	if current then
		local next_task = current + 1
		task_cache[npc] = next_task
		setElementData(npc, "npc_hlc:thistask", next_task, true)
	end
end
