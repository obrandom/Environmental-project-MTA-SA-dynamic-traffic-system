function isHLCEnabled(npc)
	return isElement(npc) and getElementData(npc,"npc_hlc") or false
end

function getNPCWalkSpeed(npc)
	if not isHLCEnabled(npc) then
		-- Silently return nil if not HLC enabled (may be in combat mode)
		return nil
	end
	return getElementData(npc,"npc_hlc:walk_speed")
end

function getNPCWeaponAccuracy(npc)
	if not isHLCEnabled(npc) then
		-- Silently return nil if not HLC enabled (may be in combat mode)
		return nil
	end
	return getElementData(npc,"npc_hlc:accuracy")
end

function getNPCDriveSpeed(npc)
	if not isHLCEnabled(npc) then
		-- Silently return nil if not HLC enabled (may be in combat mode)
		return nil
	end
	return getElementData(npc,"npc_hlc:drive_speed")
end
