-- =================================================================
--      NPC PEDESTRIAN AUDIO SYSTEM (Client-side 3D Audio)
--      Plays voice audio (ElevenLabs MP3) on NPC pedestrians
--      Two modes: REACTION (scream on damage/gunshots) and
--                 RANDOM (ambient chatter when player is nearby)
-- =================================================================

-- =================================================================
--  CONFIGURATION — Edit these values to customize
-- =================================================================

-- Female skin IDs in GTA SA (used to detect gender from ped model)
-- Add or remove IDs as needed. Everything NOT in this list = male.
local FEMALE_SKINS = {
    [9]=true, [10]=true, [11]=true, [12]=true, [13]=true,   -- Black females
    [31]=true,                                                -- Black female beach
    [38]=true, [39]=true, [40]=true, [41]=true,              -- White/Hispanic females
    [53]=true, [54]=true, [55]=true, [56]=true, [57]=true,   -- White females
    [63]=true, [64]=true, [65]=true,                          -- Las Venturas females
    [69]=true,                                                -- White female rich
    [76]=true, [77]=true,                                     -- White female shopping/business
    [85]=true, [87]=true,                                     -- Street females
    [141]=true,                                               -- Denise Robinson
    [148]=true, [150]=true, [151]=true,                       -- Various females
    [157]=true,                                               -- Female
    [192]=true, [193]=true, [194]=true, [195]=true,           -- Girlfriends
    [214]=true, [215]=true,                                   -- Female workers
    [226]=true,                                               -- Female
    [231]=true, [232]=true, [233]=true,                       -- Female variants
    [263]=true,                                               -- Female
}

-- =================================================================
--  AUDIO LIBRARY — Replace placeholder paths with your MP3s
--  Paths are relative to the resource root (npchlc_traffic/)
-- =================================================================

local AUDIO_LIBRARY = {
    male = {
        reaction = {
            -- Add your male reaction MP3s here (one per line, matching meta.xml)
            "sounds/male/reaction/re_1.mp3",
            "sounds/male/reaction/re_2.mp3",
            "sounds/male/reaction/re_3.mp3",
            "sounds/male/reaction/re_4.mp3",
            "sounds/male/reaction/re_5.mp3",



       

         
        },
        random = {
            -- Add your male random/chatter MP3s here
            "sounds/male/random/ra_1.mp3",
           
            
        },
    },
    female = {
        reaction = {
            -- Add your female reaction MP3s here
            "sounds/female/reaction/re_2.mp3",
            "sounds/female/reaction/re_3.mp3",
            "sounds/female/reaction/re_4.mp3",
            "sounds/female/reaction/re_5.mp3",
            "sounds/female/reaction/re_6.mp3",
            "sounds/female/reaction/re_7.mp3",
            "sounds/female/reaction/re_8.mp3",
        
            
        },
        random = {
            -- Add your female random/chatter MP3s here
            "sounds/female/random/ra_2.mp3",
            "sounds/female/random/ra_3.mp3",
            "sounds/female/random/ra_4.mp3",
            
        },
    },
}

-- Volume settings (0.0 to 1.0)
local REACTION_VOLUME = 0.1
local RANDOM_VOLUME = 0.1

-- 3D audio distance (meters)
local AUDIO_MAX_DISTANCE = 25
local AUDIO_MIN_DISTANCE = 5

-- Random ambient audio settings
local RANDOM_CHANCE = 0.10          -- 10% of peds will play ambient chatter
local RANDOM_INTERVAL_MIN = 15000   -- Minimum ms between random sounds (15s)
local RANDOM_INTERVAL_MAX = 45000   -- Maximum ms between random sounds (45s)

-- Cooldown to prevent audio spam on same ped (ms)
local REACTION_COOLDOWN = 3000      -- 3 seconds between reaction sounds

-- =================================================================
--  INTERNAL STATE
-- =================================================================

local activeSounds = {}       -- { [ped] = { sound = soundElement, type = "reaction"|"random" } }
local reactionCooldowns = {}  -- { [ped] = lastReactionTick }
local randomTimers = {}       -- { [ped] = timerElement }
local randomCounter = 0       -- Round-robin for random audio variety

-- =================================================================
--  HELPER FUNCTIONS
-- =================================================================

-- Detect gender from ped model
local function getPedGender(ped)
    if not isElement(ped) then return "male" end
    local model = getElementModel(ped)
    return FEMALE_SKINS[model] and "female" or "male"
end

-- Stop any active sound on a ped
local function stopPedSound(ped)
    local data = activeSounds[ped]
    if data and isElement(data.sound) then
        stopSound(data.sound)
    end
    activeSounds[ped] = nil
end

-- Stop random timer for a ped
local function stopRandomTimer(ped)
    if randomTimers[ped] and isTimer(randomTimers[ped]) then
        killTimer(randomTimers[ped])
    end
    randomTimers[ped] = nil
end

-- Full cleanup for a ped
local function cleanupPed(ped)
    stopPedSound(ped)
    stopRandomTimer(ped)
    reactionCooldowns[ped] = nil
end

-- Play a 3D audio on a ped with spatial effects
local function playPedAudio(ped, audioPath, volume, audioType)
    if not isElement(ped) then return end

    -- Stop any currently playing sound on this ped
    stopPedSound(ped)

    local px, py, pz = getElementPosition(ped)
    local sound = playSound3D(audioPath, px, py, pz, false)  -- false = not looped
    if not sound then return end

    setSoundVolume(sound, volume)
    setSoundMaxDistance(sound, AUDIO_MAX_DISTANCE)
    setSoundMinDistance(sound, AUDIO_MIN_DISTANCE)

    -- SPATIAL AUDIO: outdoor open-field reverb (no echo to avoid repetition)
    setSoundEffectEnabled(sound, "i3dl2reverb", true)

    -- Attach sound to ped so it follows movement
    attachElements(sound, ped, 0, 0, 0)

    activeSounds[ped] = {
        sound = sound,
        type = audioType
    }

    -- Auto-cleanup when sound finishes (for non-looped sounds)
    addEventHandler("onClientSoundStopped", sound, function()
        if activeSounds[ped] and activeSounds[ped].sound == source then
            activeSounds[ped] = nil
        end
    end)
end

-- =================================================================
--  REACTION AUDIO (triggered by ped_reactions_c.lua)
-- =================================================================

addEvent("onNpcReactionAudio", true)
addEventHandler("onNpcReactionAudio", root, function(ped)
    if not isElement(ped) then return end
    if getElementType(ped) ~= "ped" then return end

    -- Check cooldown
    local now = getTickCount()
    local lastReaction = reactionCooldowns[ped]
    if lastReaction and (now - lastReaction) < REACTION_COOLDOWN then return end
    reactionCooldowns[ped] = now

    -- Get gender and pick random reaction audio
    local gender = getPedGender(ped)
    local reactions = AUDIO_LIBRARY[gender] and AUDIO_LIBRARY[gender].reaction
    if not reactions or #reactions == 0 then return end

    local audioPath = reactions[math.random(#reactions)]
    playPedAudio(ped, audioPath, REACTION_VOLUME, "reaction")
end)

-- =================================================================
--  RANDOM AMBIENT AUDIO (plays periodically on nearby peds)
-- =================================================================

local function scheduleRandomAudio(ped)
    if not isElement(ped) then return end
    if randomTimers[ped] then return end  -- Already scheduled

    local interval = math.random(RANDOM_INTERVAL_MIN, RANDOM_INTERVAL_MAX)

    randomTimers[ped] = setTimer(function()
        randomTimers[ped] = nil

        if not isElement(ped) then return end
        if not isElementStreamedIn(ped) then return end
        if isPedInVehicle(ped) then return end
        if isPedDead(ped) then return end

        -- Don't play if already reacting
        local currentSound = activeSounds[ped]
        if currentSound and currentSound.type == "reaction" then
            scheduleRandomAudio(ped)
            return
        end

        -- Get gender and pick random audio (round-robin for variety)
        local gender = getPedGender(ped)
        local randoms = AUDIO_LIBRARY[gender] and AUDIO_LIBRARY[gender].random
        if not randoms or #randoms == 0 then
            scheduleRandomAudio(ped)
            return
        end

        randomCounter = randomCounter + 1
        local idx = ((randomCounter - 1) % #randoms) + 1
        local audioPath = randoms[idx]

        playPedAudio(ped, audioPath, RANDOM_VOLUME, "random")

        -- Schedule next random audio
        scheduleRandomAudio(ped)
    end, interval, 1)
end

-- =================================================================
--  STREAM IN/OUT HANDLERS
-- =================================================================

-- When a ped streams in, maybe start random ambient audio
addEventHandler("onClientElementStreamIn", root, function()
    if getElementType(source) ~= "ped" then return end
    if isPedInVehicle(source) then return end

    -- Random chance to play ambient chatter
    if math.random() < RANDOM_CHANCE then
        scheduleRandomAudio(source)
    end
end)

-- When a ped streams out, cleanup
addEventHandler("onClientElementStreamOut", root, function()
    if getElementType(source) == "ped" then
        cleanupPed(source)
    end
end)

-- When a ped is destroyed, cleanup
addEventHandler("onClientElementDestroy", root, function()
    cleanupPed(source)
end)

-- =================================================================
--  RESOURCE LIFECYCLE
-- =================================================================

-- On resource start, scan already-streamed peds
addEventHandler("onClientResourceStart", resourceRoot, function()
    for _, ped in ipairs(getElementsByType("ped", root, true)) do
        if isElementStreamedIn(ped) and not isPedInVehicle(ped) then
            if math.random() < RANDOM_CHANCE then
                scheduleRandomAudio(ped)
            end
        end
    end
end)

-- On resource stop, cleanup everything
addEventHandler("onClientResourceStop", resourceRoot, function()
    for ped, _ in pairs(activeSounds) do
        stopPedSound(ped)
    end
    for ped, _ in pairs(randomTimers) do
        stopRandomTimer(ped)
    end
    activeSounds = {}
    randomTimers = {}
    reactionCooldowns = {}
end)
