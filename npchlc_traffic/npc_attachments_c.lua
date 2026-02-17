-- =================================================================
--      NPC ATTACHMENT SYSTEM (Internal Bone Attach)
--      Replaces dependency on external bone_attach
-- =================================================================

local attachedObjects = {}

-- Helper function to check and activate attachment
local function checkAndAttach(obj)
    if not isElement(obj) then return end
    
    local data = getElementData(obj, "npc_attach_info")
    if data and isElement(data.ped) then
        setElementCollisionsEnabled(obj, false)
        attachedObjects[obj] = data
    else
        attachedObjects[obj] = nil
    end
end

-- Monitor Stream In (When object appears for player)
addEventHandler("onClientElementStreamIn", root, function()
    checkAndAttach(source)
end)

-- Monitor Data Change (If server sets data after stream or updates)
addEventHandler("onClientElementDataChange", root, function(key)
    if key == "npc_attach_info" then
        checkAndAttach(source)
    end
end)

-- Check existing objects on start
addEventHandler("onClientResourceStart", resourceRoot, function()
    for _, obj in ipairs(getElementsByType("object", root, true)) do
        checkAndAttach(obj)
    end
end)

-- Cleanup on destroy or stream out
addEventHandler("onClientElementStreamOut", root, function()
    attachedObjects[source] = nil
end)

addEventHandler("onClientElementDestroy", root, function()
    attachedObjects[source] = nil
end)

-- Main update function (PreRender for smoothness)
addEventHandler("onClientPreRender", root, function()
    for obj, data in pairs(attachedObjects) do
        if isElement(obj) and isElement(data.ped) then
            -- Check if PED is also streamed (critical check)
            if isElementStreamedIn(data.ped) then
                local bx, by, bz = getPedBonePosition(data.ped, data.bone)
                
                if bx then
                    local _, _, prz = getElementRotation(data.ped)
                    local rad = math.rad(prz)
                    local sin, cos = math.sin(rad), math.cos(rad)
                    
                    -- Apply rotation to offset
                    local finalOffX = data.ox * cos - data.oy * sin
                    local finalOffY = data.ox * sin + data.oy * cos
                    
                    setElementPosition(obj, bx + finalOffX, by + finalOffY, bz + data.oz)
                    setElementRotation(obj, data.orx, data.ory, prz + data.orz)
                end
            end
        else
            attachedObjects[obj] = nil
        end
    end
end)
