-- f_dynamic_density.lua
-- Handles time-based traffic density changes

-- Config
local UPDATE_INTERVAL_MS = 60000 -- Check time every 1 minute (was 5s, but 1min is sufficient for traffic)
local DENSITY_DEFAULT = 0.27    -- Arg 0.27 -> 0.27%
local DENSITY_PEAK = 0.30       -- Arg 0.30 -> 0.30%
local DENSITY_LOW = 0.08        -- Arg 0.08 -> 0.08%

-- Time Ranges
local TIME_PEAK_MORNING = {7, 9}   -- 07:00 - 09:00
local TIME_PEAK_EVENING = {17, 19} -- 17:00 - 19:00
local TIME_LOW_START = 0           -- 00:00
local TIME_LOW_END = 5             -- 05:00

function checkDynamicTraffic()
    -- Only proceed if auto mode is enabled (variable in f_density.lua)
    if not isTrafficAutoMode() then return end

    local h, m = getTime()
    local targetDensity = DENSITY_DEFAULT

    -- Check Ranges
    if (h >= TIME_PEAK_MORNING[1] and h < TIME_PEAK_MORNING[2]) or
       (h >= TIME_PEAK_EVENING[1] and h < TIME_PEAK_EVENING[2]) then
        targetDensity = DENSITY_PEAK
    elseif (h >= TIME_LOW_START and h < TIME_LOW_END) then
        targetDensity = DENSITY_LOW
    else
        targetDensity = DENSITY_DEFAULT
    end

    -- Apply if different from current (avoid spamming updates)
    -- function setTrafficDensity(trtype, density, isAutoCall)
    -- density arg is pre-division by 100 inside function?
    -- Yes, user said "/density 0.22" works. setTrafficDensity divides by 100.
    -- So we pass 0.27 to get 0.0027.
    
    -- Current density internal value check
    -- We need to check against (targetDensity * 0.01)
    local current = getTrafficDensity("cars") or 0
    local targetInternal = targetDensity * 0.01
    
    -- Tolerance for floating point comparison
    if math.abs(current - targetInternal) > 0.00001 then
        setTrafficDensity("cars", targetDensity, true) -- Pass raw value (0.27), function will divide by 100
        setTrafficDensity("peds", targetDensity, true)
    end
end

-- IMMEDIATE DENSITY RESET: Ensure correct density on script load
-- This runs synchronously and sets the density to default immediately
function initDynamicDensity()
    local h, m = getTime()
    local targetDensity = DENSITY_DEFAULT
    
    if (h >= TIME_PEAK_MORNING[1] and h < TIME_PEAK_MORNING[2]) or
       (h >= TIME_PEAK_EVENING[1] and h < TIME_PEAK_EVENING[2]) then
        targetDensity = DENSITY_PEAK
    elseif (h >= TIME_LOW_START and h < TIME_LOW_END) then
        targetDensity = DENSITY_LOW
    end
    
    -- Force set density immediately (isAutoCall = true to not disable auto mode)
    if traffic_density then
        traffic_density.cars = targetDensity * 0.01
        traffic_density.peds = targetDensity * 0.01
    end
end

-- Run immediately on load
initDynamicDensity()

-- Init timers for periodic checks
setTimer(checkDynamicTraffic, UPDATE_INTERVAL_MS, 0)
-- Also trigger after 1 second to catch any late changes
setTimer(checkDynamicTraffic, 1000, 1)
