--
-- c_exported_functions.lua (CORRIGIDO v2)
--

function createCorona(posX,posY,posZ,size,colorR,colorG,colorB,colorA,...)
	-- Convert to number if possible (accepts numeric strings)
	posX = tonumber(posX)
	posY = tonumber(posY)
	posZ = tonumber(posZ)
	size = tonumber(size)
	colorR = tonumber(colorR)
	colorG = tonumber(colorG)
	colorB = tonumber(colorB)
	colorA = tonumber(colorA)
	
	-- Validation after conversion
	if not (posX and posY and posZ and size and colorR and colorG and colorB and colorA) then
		outputDebugString('createCorona fail! One or more parameters are not valid numbers.')
		outputDebugString('Received values: '..tostring(posX)..', '..tostring(posY)..', '..tostring(posZ)..', '..tostring(size)..', '..tostring(colorR)..', '..tostring(colorG)..', '..tostring(colorB)..', '..tostring(colorA))
		return false
	end

	local optParam = {...}
	if (#optParam > 1) then
		outputDebugString('createCorona fail! Too many optional parameters.')
		return false
	end

	local isDepthEffect = optParam[1]
	if (type(isDepthEffect) ~= "boolean") then
		isDepthEffect = false
	end

	-- Convert boolean to the number expected by internal function (1 or 2)
	local coronaType = isDepthEffect and 2 or 1

	local SHCelementID = funcTable.createCorona(coronaType,posX,posY,posZ,size,colorR,colorG,colorB,colorA)
	
	-- More robust verification: accepts any number (including 0)
	if SHCelementID and type(SHCelementID) == "number" then
		return createElement("SHCustomCorona",tostring(SHCelementID))
	else
		outputDebugString('createCorona fail! funcTable.createCorona retornou: '..tostring(SHCelementID))
		return false
	end
end

function createMaterialCorona(texImage,posX,posY,posZ,size,colorR,colorG,colorB,colorA,...)
	if not isElement(texImage) then
		outputDebugString('createMaterialCorona fail! The provided texture is not a valid element.')
		return false
	end

	-- Convert to number if possible
	posX = tonumber(posX)
	posY = tonumber(posY)
	posZ = tonumber(posZ)
	size = tonumber(size)
	colorR = tonumber(colorR)
	colorG = tonumber(colorG)
	colorB = tonumber(colorB)
	colorA = tonumber(colorA)

	-- Validation after conversion
	if not (posX and posY and posZ and size and colorR and colorG and colorB and colorA) then
		outputDebugString('createMaterialCorona fail! One or more parameters are not valid numbers.')
		return false
	end

	local optParam = {...}
	if (#optParam > 1) then
		outputDebugString('createMaterialCorona fail! Too many optional parameters.')
		return false
	end

	local isDepthEffect = optParam[1]
	if (type(isDepthEffect) ~= "boolean") then
		isDepthEffect = false
	end

	local coronaType = isDepthEffect and 2 or 1

	local SHCelementID = funcTable.createMaterialCorona(texImage,coronaType,posX,posY,posZ,size,colorR,colorG,colorB,colorA)
	
	-- More robust verification
	if SHCelementID and type(SHCelementID) == "number" then
		return createElement("SHCustomCorona",tostring(SHCelementID))
	else
		outputDebugString('createMaterialCorona fail! funcTable.createMaterialCorona retornou: '..tostring(SHCelementID))
		return false
	end
end

function destroyCorona(w)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if type(SHCelementID) == "number" then
		return destroyElement(w) and funcTable.destroy(SHCelementID)
	else
		outputDebugString('destroyCorona fail!')
		return false
	end
end

function setCoronaMaterial(w,texImage)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if coronaTable.inputCoronas[SHCelementID] and isElement(texImage) then
		coronaTable.isInValChanged = true
		return funcTable.setMaterial(SHCelementID,texImage)
	else
		outputDebugString('setCoronaMaterial fail!')
		return false
	end
end

function setCoronaPosition(w,posX,posY,posZ)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if coronaTable.inputCoronas[SHCelementID] and type(posX) == "number" and type(posY) == "number" and type(posZ) == "number" then
		coronaTable.inputCoronas[SHCelementID].pos = {posX,posY,posZ}
		coronaTable.isInValChanged = true
		return true
	else
		outputDebugString('setCoronaPosition fail!')
		return false
	end
end

function setCoronaColor(w,colorR,colorG,colorB,colorA)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if coronaTable.inputCoronas[SHCelementID] and type(colorR) == "number" and type(colorG) == "number" and type(colorB) == "number" and type(colorA) == "number" then
		coronaTable.inputCoronas[SHCelementID].color = {colorR,colorG,colorB,colorA}
		coronaTable.isInValChanged = true
		return true
	else
		outputDebugString('setCoronaColor fail!')
		return false
	end
end

function setCoronaSize(w,size)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if coronaTable.inputCoronas[SHCelementID] and (type(size) == "number") then
		coronaTable.inputCoronas[SHCelementID].size = {size,size}
		coronaTable.inputCoronas[SHCelementID].dBias = math.min(size,1)
		coronaTable.isInValChanged = true
		return true
	else
		outputDebugString('setCoronaSize fail!')
		return false
	end
end

function setCoronaDepthBias(w,depthBias)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if coronaTable.inputCoronas[SHCelementID] and (type(depthBias) == "number") then
		coronaTable.inputCoronas[SHCelementID].dBias = depthBias
		coronaTable.isInValChanged = true
		return true
	else
		outputDebugString('setCoronaDepthBias fail!')
		return false
	end
end

function setCoronaSizeXY(w,sizeX,sizeY)
	if not isElement(w) then
		return false
	end
	local SHCelementID = tonumber(getElementID(w))
	if coronaTable.inputCoronas[SHCelementID] and (type(sizeX) == "number") and (type(sizeY) == "number") then
		coronaTable.inputCoronas[SHCelementID].size = {sizeX,sizeY}
		coronaTable.inputCoronas[SHCelementID].dBias = math.min((sizeX + sizeY)/2,1)
		coronaTable.isInValChanged = true
		return true
	else
		outputDebugString('setCoronaSizeXY fail!')
		return false
	end
end

function setCoronasDistFade(dist1,dist2)
	if (type(dist1) == "number") and (type(dist2) == "number") then
		return funcTable.setDistFade(dist1,dist2)
	else
		outputDebugString('setCoronasDistFade fail!')
		return false
	end
end

function enableDepthBiasScale(depthBiasEnable)
	if type(depthBiasEnable) == "boolean" then
		coronaTable.depthBias = depthBiasEnable
		return true
	else
		outputDebugString('enableDepthBiasScale fail!')
		return false
	end
end