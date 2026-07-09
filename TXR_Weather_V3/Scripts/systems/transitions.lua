-- TXR Weather Mod v3.0
-- systems/transitions.lua
-- Phase 8: Dawn/Dusk time stretching and Tokyo Tint

local Transitions = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil

local MODULE = "Transitions"

-- ============== CONFIGURATION ==============
-- Slow time windows (from V1.34)
local SLOW_DAWN_START = 500   -- 05:00
local SLOW_DAWN_END   = 700   -- 07:00
local SLOW_DUSK_START = 1730  -- 17:30
local SLOW_DUSK_END   = 1930  -- 19:30

-- Speed during dawn/dusk, expressed as a fraction of normal speed. Lower factor
-- = slower time = the window lingers longer in real time. 1.34 used 40%; we
-- deepen it so dusk/dawn last noticeably longer. Both are recomputed from config
-- in Init() (NORMAL_SPEED from Config.TimeOfDay.DefaultSpeed).
local NORMAL_SPEED = 53.333          -- overwritten from config in Init
local SLOW_FACTOR  = 0.20            -- fraction of normal during the slow window
local SLOW_SPEED   = NORMAL_SPEED * SLOW_FACTOR

-- Tokyo Tint timing (in TOD units, from V1.34)
local TINT_LEAD_TOD = 240        -- Start tint this much BEFORE slow window
local TINT_FADE_OUT_EXTRA = 140  -- Continue tint this much AFTER slow window

-- Peak tint times (at actual sunrise/sunset)
local DAWN_PEAK_TOD = 680     -- 06:48 (actual sunrise)
local DUSK_PEAK_TOD = 1800    -- 18:00 (actual sunset)

-- Tokyo Tint colors (RGBA)
local TOKYO_TINT_COLORS = {
    orangeStrong = {R = 1.00, G = 0.36, B = 0.14, A = 1.0},
    orangeSoft   = {R = 1.00, G = 0.55, B = 0.22, A = 1.0},
    redStrong    = {R = 0.92, G = 0.16, B = 0.16, A = 1.0},
    pink         = {R = 1.00, G = 0.45, B = 0.55, A = 1.0},
}

-- UDS property names for color control
local PROP_SUN_COLOR = "Sun Light Color"
local PROP_HORIZON_COLOR = "Horizon Color"
local PROP_CLOUD_LIGHT_COLOR = "Cloud Light Color"
local PROP_SIMULATION_SPEED = "Simulation Speed"

-- ============== STATE ==============
local isInitialized = false
local isInSlowWindow = false
local slowSpeedActive = false  -- Track if we've set slow speed
local currentTintStrength = 0.0
local lastTOD = nil
local originalColors = nil  -- Store original colors for blending

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local success, mod = pcall(require, "systems.actors")
        if success then Actors = mod end
    end
    return Actors
end

local function getTimeOfDay()
    if not TimeOfDay then
        local success, mod = pcall(require, "systems.time_of_day")
        if success then TimeOfDay = mod end
    end
    return TimeOfDay
end

-- Sun-elevation window bounds (2026-07-07): the slow window is keyed to the
-- SUN, not the clock. The stock game's date advances every in-game midnight,
-- so sunrise/sunset drift seasonally - fixed TOD windows aim at the wrong
-- sky within days of play (the measured August dusk collapse was 19:15-20:05
-- while the old window ended at 19:30). Elevation centers the window on the
-- actual event wherever the date drifts. TOD windows remain the FALLBACK when
-- elevation is unavailable (LightCycle off / not yet armed).
local SLOW_ELEV_MAX = 8.0
local SLOW_ELEV_MIN = -8.0

local LightCycleMod = nil
local function getSunElevation()
    if not LightCycleMod then
        local ok, mod = pcall(require, "systems.light_cycle")
        if ok then LightCycleMod = mod end
    end
    if LightCycleMod and LightCycleMod.IsActive and LightCycleMod.IsActive()
       and LightCycleMod.GetSunElevation then
        local ok, v = pcall(LightCycleMod.GetSunElevation)
        if ok then return v end
    end
    return nil
end

--- Check if the slow window is active (for speed control). Elevation-keyed
--- when the sun is readable; falls back to the configured TOD windows.
--- @param tod number Time of day (0-2400)
--- @return boolean inWindow
--- @return string|nil windowType "dawn" or "dusk" or nil
local function isInSlowTimeWindow(tod)
    local elev = getSunElevation()
    if type(elev) == "number" then
        if elev <= SLOW_ELEV_MAX and elev >= SLOW_ELEV_MIN then
            -- dawn vs dusk only matters for the log; morning = dawn
            return true, (tod < 1200 and "dawn" or "dusk")
        end
        return false, nil
    end
    if tod >= SLOW_DAWN_START and tod <= SLOW_DAWN_END then
        return true, "dawn"
    elseif tod >= SLOW_DUSK_START and tod <= SLOW_DUSK_END then
        return true, "dusk"
    end
    return false, nil
end

--- Check if TOD is in tint window (extends beyond slow window)
--- @param tod number Time of day (0-2400)
--- @return boolean inWindow
--- @return string|nil windowType "dawn" or "dusk" or nil
local function isInTintWindow(tod)
    -- Dawn tint: starts TINT_LEAD_TOD before slow window, ends TINT_FADE_OUT_EXTRA after
    local dawnTintStart = SLOW_DAWN_START - TINT_LEAD_TOD
    local dawnTintEnd = SLOW_DAWN_END + TINT_FADE_OUT_EXTRA
    
    -- Dusk tint: same pattern
    local duskTintStart = SLOW_DUSK_START - TINT_LEAD_TOD
    local duskTintEnd = SLOW_DUSK_END + TINT_FADE_OUT_EXTRA
    
    if tod >= dawnTintStart and tod <= dawnTintEnd then
        return true, "dawn"
    elseif tod >= duskTintStart and tod <= duskTintEnd then
        return true, "dusk"
    end
    return false, nil
end

--- Calculate tint strength based on TOD position in extended tint window
--- @param tod number
--- @param windowType string "dawn" or "dusk"
--- @return number strength 0.0-1.0
local function calculateTintStrength(tod, windowType)
    local windowStart, windowEnd, peakTOD, tintStart, tintEnd
    
    if windowType == "dawn" then
        windowStart = SLOW_DAWN_START
        windowEnd = SLOW_DAWN_END
        peakTOD = DAWN_PEAK_TOD
        tintStart = windowStart - TINT_LEAD_TOD
        tintEnd = windowEnd + TINT_FADE_OUT_EXTRA
    elseif windowType == "dusk" then
        windowStart = SLOW_DUSK_START
        windowEnd = SLOW_DUSK_END
        peakTOD = DUSK_PEAK_TOD
        tintStart = windowStart - TINT_LEAD_TOD
        tintEnd = windowEnd + TINT_FADE_OUT_EXTRA
    else
        return 0.0
    end
    
    -- Before peak: fade in
    if tod < peakTOD then
        local fadeRange = peakTOD - tintStart
        local progress = tod - tintStart
        return math.max(0.0, math.min(1.0, progress / fadeRange))
    else
        -- After peak: fade out (slower, using TINT_FADE_OUT_EXTRA)
        local fadeRange = tintEnd - peakTOD
        local progress = tintEnd - tod
        return math.max(0.0, math.min(1.0, progress / fadeRange))
    end
end

--- Lerp between two colors
--- @param colorA table {R, G, B, A}
--- @param colorB table {R, G, B, A}
--- @param t number 0.0-1.0
--- @return table|nil
local function lerpColor(colorA, colorB, t)
    -- Validate inputs are tables with numeric values
    if type(colorA) ~= "table" or type(colorB) ~= "table" then
        return nil
    end
    
    local aR = tonumber(colorA.R)
    local aG = tonumber(colorA.G)
    local aB = tonumber(colorA.B)
    local aA = tonumber(colorA.A)
    local bR = tonumber(colorB.R)
    local bG = tonumber(colorB.G)
    local bB = tonumber(colorB.B)
    local bA = tonumber(colorB.A)
    
    if not (aR and aG and aB and aA and bR and bG and bB and bA) then
        return nil
    end
    
    return {
        R = aR + (bR - aR) * t,
        G = aG + (bG - aG) * t,
        B = aB + (bB - aB) * t,
        A = aA + (bA - aA) * t,
    }
end

--- Read color property from UDS
--- @param propName string
--- @return table|nil {R, G, B, A}
local function readColorProperty(propName)
    local actors = getActors()
    if not actors then return nil end
    
    local uds = actors.GetUDS()
    if not uds then return nil end
    
    local color = nil
    pcall(function()
        local rawColor = uds[propName]
        if rawColor then
            -- UE4SS returns LinearColor as UObject - extract numeric values
            local r = tonumber(rawColor.R) or 1.0
            local g = tonumber(rawColor.G) or 1.0
            local b = tonumber(rawColor.B) or 1.0
            local a = tonumber(rawColor.A) or 1.0
            color = {R = r, G = g, B = b, A = a}
        end
    end)
    
    return color
end

--- Write color property to UDS
--- @param propName string
--- @param color table {R, G, B, A}
--- @return boolean success
local function writeColorProperty(propName, color)
    local actors = getActors()
    if not actors then return false end
    
    local uds = actors.GetUDS()
    if not uds then return false end
    
    local ok = pcall(function()
        uds[propName] = color
    end)
    
    return ok
end

--- Store original colors for later restoration
local function storeOriginalColors()
    if originalColors then return end  -- Already stored
    
    originalColors = {
        sunColor = readColorProperty(PROP_SUN_COLOR),
        horizonColor = readColorProperty(PROP_HORIZON_COLOR),
        cloudLightColor = readColorProperty(PROP_CLOUD_LIGHT_COLOR),
    }
    
    -- Debug: log what we got
    local sunOk = originalColors.sunColor and originalColors.sunColor.R
    local horizonOk = originalColors.horizonColor and originalColors.horizonColor.R
    local cloudOk = originalColors.cloudLightColor and originalColors.cloudLightColor.R
    Log.Debug(MODULE, "Stored original colors", {
        sunOk = sunOk ~= nil,
        horizonOk = horizonOk ~= nil,
        cloudOk = cloudOk ~= nil
    })
end

--- Apply Tokyo tint at given strength
--- @param strength number 0.0-1.0
--- @param windowType string "dawn" or "dusk"
local function applyTokyoTint(strength, windowType)
    if strength < 0.01 then return end
    if not originalColors then return end
    
    -- Select tint color based on window type
    local tintColor
    if windowType == "dawn" then
        tintColor = TOKYO_TINT_COLORS.orangeSoft
    else
        tintColor = TOKYO_TINT_COLORS.orangeStrong
    end
    
    -- Blend original colors with tint
    if originalColors.sunColor then
        local blended = lerpColor(originalColors.sunColor, tintColor, strength * 0.7)
        if blended then
            writeColorProperty(PROP_SUN_COLOR, blended)
        end
    end
    
    if originalColors.horizonColor then
        local horizonTint = lerpColor(tintColor, TOKYO_TINT_COLORS.pink, 0.3)
        if horizonTint then
            local blended = lerpColor(originalColors.horizonColor, horizonTint, strength * 0.5)
            if blended then
                writeColorProperty(PROP_HORIZON_COLOR, blended)
            end
        end
    end
    
    if originalColors.cloudLightColor then
        local blended = lerpColor(originalColors.cloudLightColor, tintColor, strength * 0.4)
        if blended then
            writeColorProperty(PROP_CLOUD_LIGHT_COLOR, blended)
        end
    end
end

--- Restore original colors
local function restoreOriginalColors()
    if not originalColors then return end
    
    if originalColors.sunColor then
        writeColorProperty(PROP_SUN_COLOR, originalColors.sunColor)
    end
    if originalColors.horizonColor then
        writeColorProperty(PROP_HORIZON_COLOR, originalColors.horizonColor)
    end
    if originalColors.cloudLightColor then
        writeColorProperty(PROP_CLOUD_LIGHT_COLOR, originalColors.cloudLightColor)
    end
    
    originalColors = nil
    Log.Debug(MODULE, "Restored original colors")
end

--- Set simulation speed
--- @param speed number
--- @param force boolean|nil Force set even if already at this speed
local function setSimulationSpeed(speed, force)
    local actors = getActors()
    if not actors then return end
    
    local uds = actors.GetUDS()
    if not uds then return end
    
    local ok = pcall(function()
        uds[PROP_SIMULATION_SPEED] = speed
    end)
    
    -- Only log on state change
    if ok and force then
        Log.Info(MODULE, "Simulation speed set", {speed = speed})
    end
end

-- ============== PUBLIC API ==============

--- Initialize transitions module
--- @return boolean success
function Transitions.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    Log.Info(MODULE, "Initializing transitions module")
    
    -- Normal speed tracks the time-of-day default so the post-window restore matches it.
    if Config.TimeOfDay and Config.TimeOfDay.DefaultSpeed then
        NORMAL_SPEED = Config.TimeOfDay.DefaultSpeed
    end

    -- Read config overrides if present
    if Config.Transitions then
        if Config.Transitions.SlowDawnStart then SLOW_DAWN_START = Config.Transitions.SlowDawnStart end
        if Config.Transitions.SlowDawnEnd then SLOW_DAWN_END = Config.Transitions.SlowDawnEnd end
        if Config.Transitions.SlowDuskStart then SLOW_DUSK_START = Config.Transitions.SlowDuskStart end
        if Config.Transitions.SlowDuskEnd then SLOW_DUSK_END = Config.Transitions.SlowDuskEnd end
        if Config.Transitions.SlowFactor then SLOW_FACTOR = Config.Transitions.SlowFactor end
        if Config.Transitions.SlowElevMax then SLOW_ELEV_MAX = Config.Transitions.SlowElevMax end
        if Config.Transitions.SlowElevMin then SLOW_ELEV_MIN = Config.Transitions.SlowElevMin end
        -- Legacy absolute override still honored if someone set it.
        if Config.Transitions.SlowSpeed then SLOW_FACTOR = Config.Transitions.SlowSpeed / NORMAL_SPEED end
        if Config.Transitions.Enabled == false then
            Log.Info(MODULE, "Transitions disabled in config")
            isInitialized = true
            return true
        end
    end

    -- Slow speed is a fraction of normal so it tracks any DefaultSpeed change.
    SLOW_SPEED = NORMAL_SPEED * SLOW_FACTOR
    Log.Info(MODULE, "Slow-time configured", {
        normal = NORMAL_SPEED,
        factor = SLOW_FACTOR,
        slow = string.format("%.2f", SLOW_SPEED),
    })
    
    isInitialized = true
    State.SetModuleStatus("transitions", true)
    
    return true
end

--- Main tick function - call every frame/tick
function Transitions.Tick()
    if not isInitialized then return end
    if Config.Transitions and Config.Transitions.Enabled == false then return end
    
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end
    
    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end
    
    local tod = getTimeOfDay()
    if not tod then return end
    
    local currentTOD = tod.GetCurrentTOD()
    if not currentTOD then return end
    
    -- Check both windows separately
    local inSlowWindow, slowType = isInSlowTimeWindow(currentTOD)
    local inTintWindow, tintType = isInTintWindow(currentTOD)
    
    -- Handle SLOW WINDOW (speed control)
    if inSlowWindow then
        if not isInSlowWindow then
            -- Just entered slow window
            Log.Info(MODULE, "Entering slow window", {type = slowType, tod = currentTOD})
            isInSlowWindow = true
            slowSpeedActive = false
        end
        
        -- Continuously enforce slow speed
        local speedMode = tod.GetSpeedMode and tod.GetSpeedMode()
        if speedMode == "normal" or speedMode == nil then
            local logIt = not slowSpeedActive
            setSimulationSpeed(SLOW_SPEED, logIt)
            slowSpeedActive = true
        end
    else
        if isInSlowWindow then
            -- Just exited slow window
            Log.Info(MODULE, "Exiting slow window", {tod = currentTOD})
            isInSlowWindow = false
            slowSpeedActive = false
            
            -- Restore normal speed
            local speedMode = tod.GetSpeedMode and tod.GetSpeedMode()
            if speedMode == "normal" or speedMode == nil then
                setSimulationSpeed(NORMAL_SPEED, true)
            end
        end
    end
    
    -- Handle TINT WINDOW (color control) - extends beyond slow window
    if inTintWindow then
        if not originalColors then
            -- First time in tint window - store colors
            Log.Info(MODULE, "Entering tint window", {type = tintType, tod = currentTOD})
            storeOriginalColors()
        end
        
        -- Calculate and apply tint
        local strength = calculateTintStrength(currentTOD, tintType)
        if math.abs(strength - currentTintStrength) > 0.01 then
            currentTintStrength = strength
            applyTokyoTint(strength, tintType)
            Log.Debug(MODULE, "Tint applied", {strength = string.format("%.2f", strength)})
        end
    else
        if originalColors then
            -- Just exited tint window
            Log.Info(MODULE, "Exiting tint window", {tod = currentTOD})
            currentTintStrength = 0.0
            restoreOriginalColors()
        end
    end
    
    lastTOD = currentTOD
end

--- Force exit from slow window (for manual control)
function Transitions.ForceExit()
    if isInSlowWindow then
        isInSlowWindow = false
        slowSpeedActive = false
        currentTintStrength = 0.0
        setSimulationSpeed(NORMAL_SPEED, true)
        restoreOriginalColors()
        Log.Info(MODULE, "Forced exit from slow window")
    end
end

--- Check if currently in slow window
--- @return boolean
function Transitions.IsInSlowWindow()
    return isInSlowWindow
end

--- Get current tint strength
--- @return number 0.0-1.0
function Transitions.GetTintStrength()
    return currentTintStrength
end

--- Get status for debugging
--- @return table
function Transitions.GetStatus()
    local dawnTintStart = SLOW_DAWN_START - TINT_LEAD_TOD
    local dawnTintEnd = SLOW_DAWN_END + TINT_FADE_OUT_EXTRA
    local duskTintStart = SLOW_DUSK_START - TINT_LEAD_TOD
    local duskTintEnd = SLOW_DUSK_END + TINT_FADE_OUT_EXTRA
    
    return {
        initialized = isInitialized,
        inSlowWindow = isInSlowWindow,
        inTintWindow = originalColors ~= nil,
        tintStrength = currentTintStrength,
        lastTOD = lastTOD,
        slowDawnWindow = string.format("%d-%d", SLOW_DAWN_START, SLOW_DAWN_END),
        slowDuskWindow = string.format("%d-%d", SLOW_DUSK_START, SLOW_DUSK_END),
        tintDawnWindow = string.format("%d-%d", dawnTintStart, dawnTintEnd),
        tintDuskWindow = string.format("%d-%d", duskTintStart, duskTintEnd),
    }
end

--- Check if module is initialized
--- @return boolean
function Transitions.IsInitialized()
    return isInitialized
end

return Transitions
