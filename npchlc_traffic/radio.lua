-- =================================================================
--      NPC RADIO SYSTEM (Client-side 3D Audio)
--      Plays radio streams on NPC traffic vehicles
--      5% of traffic spawns with radio enabled (set in generate.lua)
--      Emergency vehicles play police radio instead
-- =================================================================

-- =================================================================
--  CONFIGURATION — Edit these values to customize the radio system
-- =================================================================

-- List of CIVILIAN radio stations (URL + friendly name)
-- Add or remove entries as you wish. Each NPC picks one at random.
local RADIO_STATIONS = {
    { url = "https://res.cloudinary.com/dnhnxvtgu/raw/upload/v1771267671/listen-radio_2_ukjrgx.pls",         name = "Lo-Fi Beats" },
    { url = "https://res.cloudinary.com/dnhnxvtgu/raw/upload/v1771267785/internet-radio.com.playlist_ug8aut.pls",        name = "Classic Rock" },
    { url = "https://res.cloudinary.com/dnhnxvtgu/raw/upload/v1771267816/listen-radio_gglzh2.pls",        name = "Pop Hits" },
    
}

-- Police / Emergency radio station (single URL for all emergency vehicles)
local POLICE_RADIO_STATION = {
    url  = "https://res.cloudinary.com/dnhnxvtgu/video/upload/v1771270818/audio-editor-output_yb2anm.mp3",
    name = "Police Scanner"
}

-- Base volume for NPC radios (0.0 to 1.0)
local RADIO_VOLUME = 0.1

-- Volume for police radio (usually lower, like static chatter)
local POLICE_RADIO_VOLUME = 0.1

-- Maximum distance (in meters) at which the radio can be heard
local RADIO_MAX_DISTANCE = 30

-- Minimum distance — full volume within this range
local RADIO_MIN_DISTANCE = 20

-- =================================================================
--  INTERNAL STATE — Do not edit below unless you know what you do
-- =================================================================

local activeRadios = {}  -- { [vehicle] = { sound = soundElement, station = stationInfo } }
local stationCounter = 0  -- Round-robin counter: guarantees each vehicle gets a different station

-- -----------------------------------------------------------------
--  Helper: Start radio for a vehicle
-- -----------------------------------------------------------------
local function startRadioForVehicle(vehicle)
    if not isElement(vehicle) then return end
    if activeRadios[vehicle] then return end  -- Already playing

    -- Check the server flag
    local hasRadio = getElementData(vehicle, "npc.hasRadio")
    if not hasRadio then return end

    -- Determine which station to play
    local radioType = getElementData(vehicle, "npc.radioType")
    local station
    local volume = RADIO_VOLUME

    if radioType == "emergency" then
        -- Emergency vehicles always play police radio
        station = POLICE_RADIO_STATION
        volume = POLICE_RADIO_VOLUME
    else
        -- Civilian vehicles: round-robin through stations so each vehicle is different
        stationCounter = stationCounter + 1
        local idx = ((stationCounter - 1) % #RADIO_STATIONS) + 1
        station = RADIO_STATIONS[idx]
    end

    if not station then return end

    -- Get vehicle position for initial sound placement
    local vx, vy, vz = getElementPosition(vehicle)

    -- Create 3D sound at vehicle position
    local sound = playSound3D(station.url, vx, vy, vz, true)  -- true = looped stream
    if not sound then return end

    -- Configure sound properties
    setSoundVolume(sound, volume)
    setSoundMaxDistance(sound, RADIO_MAX_DISTANCE)
    setSoundMinDistance(sound, RADIO_MIN_DISTANCE)

    -- SPATIAL AUDIO: outdoor open-field reverb (no echo to avoid repetition)
    setSoundEffectEnabled(sound, "i3dl2reverb", true)

    -- Attach sound to vehicle so it moves with it
    attachElements(sound, vehicle, 0, 0, 0)

    -- Store reference for cleanup
    activeRadios[vehicle] = {
        sound = sound,
        station = station
    }
end

-- -----------------------------------------------------------------
--  Helper: Stop radio for a vehicle
-- -----------------------------------------------------------------
local function stopRadioForVehicle(vehicle)
    local data = activeRadios[vehicle]
    if not data then return end

    if isElement(data.sound) then
        stopSound(data.sound)
    end

    activeRadios[vehicle] = nil
end

-- -----------------------------------------------------------------
--  Event: Vehicle streams in — check if it should have radio
-- -----------------------------------------------------------------
addEventHandler("onClientElementStreamIn", root, function()
    if getElementType(source) == "vehicle" then
        startRadioForVehicle(source)
    end
end)

-- -----------------------------------------------------------------
--  Event: Element data changes (in case flag is set after stream-in)
-- -----------------------------------------------------------------
addEventHandler("onClientElementDataChange", root, function(key)
    if key == "npc.hasRadio" and getElementType(source) == "vehicle" then
        local hasRadio = getElementData(source, "npc.hasRadio")
        if hasRadio then
            startRadioForVehicle(source)
        else
            stopRadioForVehicle(source)
        end
    end
end)

-- -----------------------------------------------------------------
--  Event: Vehicle streams out — stop radio to save resources
-- -----------------------------------------------------------------
addEventHandler("onClientElementStreamOut", root, function()
    if getElementType(source) == "vehicle" then
        stopRadioForVehicle(source)
    end
end)

-- -----------------------------------------------------------------
--  Event: Vehicle destroyed — cleanup
-- -----------------------------------------------------------------
addEventHandler("onClientElementDestroy", root, function()
    stopRadioForVehicle(source)
end)

-- -----------------------------------------------------------------
--  Event: Resource start — scan already-streamed vehicles
-- -----------------------------------------------------------------
addEventHandler("onClientResourceStart", resourceRoot, function()
    for _, vehicle in ipairs(getElementsByType("vehicle", root, true)) do
        if isElementStreamedIn(vehicle) then
            startRadioForVehicle(vehicle)
        end
    end
end)

-- -----------------------------------------------------------------
--  Event: Resource stop — cleanup all active radios
-- -----------------------------------------------------------------
addEventHandler("onClientResourceStop", resourceRoot, function()
    for vehicle, _ in pairs(activeRadios) do
        stopRadioForVehicle(vehicle)
    end
    activeRadios = {}
end)
