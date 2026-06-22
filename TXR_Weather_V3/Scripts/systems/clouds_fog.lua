-- TXR Weather Mod v3.0
-- systems/clouds_fog.lua
-- Dynamic cloud coverage and fog density control

local CloudsFog = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local State = require("core.state")
local Config = require("config")
local Actors = require("systems.actors")

local MODULE = "CloudsFog"

-- Lazy-loaded once and cached (avoids a per-tick require/pcall in Tick)
local TimeOfDayMod = nil
local function getTimeOfDay()
    if not TimeOfDayMod then
        local ok, mod = pcall(require, "systems.time_of_day")
        if ok then TimeOfDayMod = mod end
    end
    return TimeOfDayMod
end

-- ============== PROPERTY NAMES ==============
local PROP_CLOUD_COVERAGE = "Cloud Coverage"
local PROP_CLOUD_MANUAL_OVERRIDE = "Cloud Coverage - Manual Override"
local PROP_FOG = "Fog"
local PROP_FOG_MANUAL_OVERRIDE = "Fog - Manual Override"

-- ============== STATE ==============
local internalState = {
    initialized = false,
    manualOverrideSet = false,
    tickCount = 0,
    
    -- Current smoothed values
    cloudCurrent = nil,
    fogCurrent = nil,
    
    -- Target values for smooth transitions
    cloudTarget = nil,
    fogTarget = nil,
    
    -- Mood system for day-to-day variation
    moodTarget = 0,
    moodCurrent = 0,
    
    -- Morning profile
    morningProfile = "partial",
    morningWasActive = false,
    
    -- Reference time for drift calculations
    driftT0 = 0,
}

-- ============== MORNING PROFILES ==============
-- Profiles affect cloud/fog bias during dawn hours

local MORNING_PROFILES = {
    clear = { cloudBias = -0.9, fogBias = -0.25 },
    partial = { cloudBias = 0.4, fogBias = 0.05 },
    overcast = { cloudBias = 1.3, fogBias = 0.30 },
    foggy = { cloudBias = 0.2, fogBias = 2.2 },
}

--- Pick a random morning profile based on weights
--- @return string Profile name
local function pickMorningProfile()
    local weights = Config.CloudsFog.MorningProfileWeights
    if not weights then
        return "partial"
    end
    
    local pool = {}
    for name, weight in pairs(weights) do
        table.insert(pool, { name = name, weight = weight })
    end
    
    return Utils.WeightedPick(pool) or "partial"
end

--- Calculate morning factor (0-1) based on time of day
--- @param tod number Time of day (0-2400)
--- @return number Factor 0-1
local function getMorningFactor(tod)
    if not Config.CloudsFog.MorningProfilesEnabled then
        return 0
    end
    
    local start = Config.TimeOfDay.DawnStart + (Config.CloudsFog.MorningStartOffset or 0)
    local endTOD = Config.TimeOfDay.DawnStart + (Config.CloudsFog.MorningEndOffset or 200)
    local edge = Config.CloudsFog.MorningBlendEdge or 50
    
    if tod < start or tod > endTOD then
        return 0
    end
    
    -- Smooth fade in and out
    local fadeIn = Utils.SmoothStep((tod - start) / math.max(edge, 1))
    local fadeOut = Utils.SmoothStep((endTOD - tod) / math.max(edge, 1))
    
    return Utils.Clamp(fadeIn * fadeOut, 0, 1)
end

--- Get morning biases for current profile
--- @return number cloudBias, number fogBias
local function getMorningBiases()
    if not Config.CloudsFog.MorningProfilesEnabled then
        return 0, 0
    end
    
    local profile = MORNING_PROFILES[internalState.morningProfile]
    if not profile then
        return 0, 0
    end
    
    return profile.cloudBias, profile.fogBias
end

-- ============== TARGET CALCULATIONS ==============

--- Calculate target cloud coverage based on time of day
--- @param tod number Time of day (0-2400)
--- @return number Target cloud coverage (0-10)
function CloudsFog.TargetCloudCoverage(tod)
    local frac = (tod % 2400) / 2400
    local t = os.clock() - internalState.driftT0
    
    -- Base diurnal curve
    local diurnal = 0.5 * (1.0 - math.cos(2.0 * math.pi * (frac + 0.15)))
    
    -- Drift - slow oscillation over minutes
    local drift = Config.CloudsFog.CloudDriftAmplitude * 
        (0.5 * (1.0 - math.cos(2.0 * math.pi * (t / Config.CloudsFog.CloudDriftPeriod))))
    
    -- Micro jitter - faster oscillation
    local jitter = Config.CloudsFog.CloudJitterAmplitude * 
        math.sin(2.0 * math.pi * (t / Config.CloudsFog.CloudJitterPeriod + 0.37))
    
    -- Dawn/Dusk boost
    local ddFactor = Utils.DawnDuskFactor(tod,
        Config.TimeOfDay.DawnStart, Config.TimeOfDay.DawnEnd,
        Config.TimeOfDay.DuskStart, Config.TimeOfDay.DuskEnd)
    
    if ddFactor > 0.0001 then
        drift = drift + (0.45 * ddFactor) * math.sin(2.0 * math.pi * (t / 12.0))
        jitter = jitter + (0.20 * ddFactor) * math.sin(2.0 * math.pi * (t / 6.5) + 1.1)
    end
    
    -- Calculate base value
    local value = Config.CloudsFog.CloudMin + 
        (Config.CloudsFog.CloudMax - Config.CloudsFog.CloudMin) * diurnal + 
        drift + jitter
    
    -- Morning profile bias
    local mFactor = getMorningFactor(tod)
    if mFactor > 0.0001 then
        local cloudBias, _ = getMorningBiases()
        value = value + (cloudBias * mFactor)
    end
    
    -- Day mood influence
    if Config.CloudsFog.MoodEnabled then
        value = value + (internalState.moodCurrent * Config.CloudsFog.MoodCloudScale)
    end
    
    return Utils.Clamp(value, 0, 10)
end

--- Calculate target fog density based on time of day
--- @param tod number Time of day (0-2400)
--- @return number Target fog density (0-10)
function CloudsFog.TargetFog(tod)
    local frac = (tod % 2400) / 2400
    local t = os.clock() - internalState.driftT0
    
    -- Base diurnal curve with phase shift
    local diurnal = 0.5 * (1.0 - math.cos(2.0 * math.pi * (frac + Config.CloudsFog.FogPhaseShift)))
    
    -- Drift
    local drift = Config.CloudsFog.FogDriftAmplitude * 
        (0.5 * (1.0 - math.cos(2.0 * math.pi * (t / 105.0))))
    
    -- Dawn/Dusk boost
    local ddFactor = Utils.DawnDuskFactor(tod,
        Config.TimeOfDay.DawnStart, Config.TimeOfDay.DawnEnd,
        Config.TimeOfDay.DuskStart, Config.TimeOfDay.DuskEnd)
    
    if ddFactor > 0.0001 then
        drift = drift + 0.25 * ddFactor
    end
    
    -- Calculate base value
    local value = Config.CloudsFog.FogMin + 
        (Config.CloudsFog.FogMax - Config.CloudsFog.FogMin) * diurnal + 
        drift
    
    -- Morning profile bias
    local mFactor = getMorningFactor(tod)
    if mFactor > 0.0001 then
        local _, fogBias = getMorningBiases()
        value = value + (fogBias * mFactor)
    end
    
    -- Day mood influence
    if Config.CloudsFog.MoodEnabled then
        value = value + (internalState.moodCurrent * Config.CloudsFog.MoodFogScale)
    end
    
    return Utils.Clamp(value, 0, 10)
end

-- ============== UDW PROPERTY ACCESS ==============

--- Set manual override flags on UDW (required for our writes to take effect)
local function ensureManualOverride()
    if internalState.manualOverrideSet then
        return true
    end
    
    local udw = Actors.GetUDW()
    if not udw then
        return false
    end
    
    local cloudOk = pcall(function() udw[PROP_CLOUD_MANUAL_OVERRIDE] = true end)
    local fogOk = pcall(function() udw[PROP_FOG_MANUAL_OVERRIDE] = true end)
    
    if cloudOk and fogOk then
        internalState.manualOverrideSet = true
        Log.Info(MODULE, "Manual override flags set")
        return true
    end
    
    return false
end

--- Write cloud coverage to UDW
--- @param value number
--- @return boolean success
local function writeCloudCoverage(value)
    local udw = Actors.GetUDW()
    if not udw then return false end
    
    local success = pcall(function() udw[PROP_CLOUD_COVERAGE] = value end)
    return success
end

--- Write fog density to UDW
--- @param value number
--- @return boolean success
local function writeFog(value)
    local udw = Actors.GetUDW()
    if not udw then return false end
    
    local success = pcall(function() udw[PROP_FOG] = value end)
    return success
end

--- Read current cloud coverage from UDW
--- @return number|nil
function CloudsFog.GetCloudCoverage()
    local udw = Actors.GetUDW()
    if not udw then return nil end
    
    local value = nil
    pcall(function() value = udw[PROP_CLOUD_COVERAGE] end)
    return Utils.ToNumber(value, nil)
end

--- Read current fog density from UDW
--- @return number|nil
function CloudsFog.GetFog()
    local udw = Actors.GetUDW()
    if not udw then return nil end
    
    local value = nil
    pcall(function() value = udw[PROP_FOG] end)
    return Utils.ToNumber(value, nil)
end

-- ============== PUBLIC API ==============

--- Initialize clouds/fog module
function CloudsFog.Init()
    Log.Info(MODULE, "Initializing clouds/fog module")
    
    internalState.driftT0 = os.clock()
    internalState.morningProfile = pickMorningProfile()
    internalState.moodTarget = (math.random() * 2.0 - 1.0)
    internalState.moodCurrent = internalState.moodTarget
    internalState.initialized = true
    internalState.manualOverrideSet = false
    internalState.tickCount = 0
    
    State.SetModuleStatus("cloudsFog", true)
    
    Log.Debug(MODULE, "Initialized", {
        morningProfile = internalState.morningProfile,
        mood = internalState.moodTarget
    })
    
    return true
end

--- Set cloud coverage directly (bypasses automatic calculations)
--- @param value number Cloud coverage (0-10)
--- @param immediate boolean|nil If true, apply immediately
--- @return boolean success
function CloudsFog.SetCloudCoverage(value, immediate)
    ensureManualOverride()
    value = Utils.Clamp(value, 0, 10)
    
    if immediate then
        -- Write directly and update state
        local success = writeCloudCoverage(value)
        if success then
            internalState.cloudCurrent = value
            internalState.cloudTarget = nil  -- Clear any pending target
            Log.Debug(MODULE, "Set cloud coverage immediate", {value = value})
        end
        return success
    else
        -- Set target for smooth transition
        internalState.cloudTarget = value
        Log.Debug(MODULE, "Set cloud coverage target", {value = value})
        return true
    end
end

--- Set fog density directly (bypasses automatic calculations)
--- @param value number Fog density (0-10)
--- @param immediate boolean|nil If true, apply immediately
--- @return boolean success
function CloudsFog.SetFog(value, immediate)
    ensureManualOverride()
    value = Utils.Clamp(value, 0, 10)
    
    if immediate then
        -- Write directly and update state
        local success = writeFog(value)
        if success then
            internalState.fogCurrent = value
            internalState.fogTarget = nil  -- Clear any pending target
            Log.Debug(MODULE, "Set fog immediate", {value = value})
        end
        return success
    else
        -- Set target for smooth transition
        internalState.fogTarget = value
        Log.Debug(MODULE, "Set fog target", {value = value})
        return true
    end
end

--- Apply values from a weather preset
--- @param cloudValue number|nil Cloud coverage (nil to skip)
--- @param fogValue number|nil Fog density (nil to skip)
--- @param immediate boolean|nil If true, apply immediately without smoothing
function CloudsFog.ApplyPreset(cloudValue, fogValue, immediate)
    ensureManualOverride()
    
    -- Set state targets so Tick() knows a preset is active
    State.SetPresetCloudTarget(cloudValue)
    State.SetPresetFogTarget(fogValue)
    State.SetPresetActive(cloudValue ~= nil or fogValue ~= nil)
    
    if cloudValue ~= nil then
        CloudsFog.SetCloudCoverage(cloudValue, immediate)
    end
    
    if fogValue ~= nil then
        CloudsFog.SetFog(fogValue, immediate)
    end
    
    Log.Info(MODULE, "Applied preset values", {
        cloud = cloudValue,
        fog = fogValue,
        immediate = immediate
    })
end

--- Main tick function - updates clouds and fog based on time
--- @param dt number|nil Delta time in seconds
function CloudsFog.Tick(dt)
    if not Config.CloudsFog.Enabled then return end
    if not Actors.IsOnCourse() then return end
    
    dt = dt or (Config.MainLoop.TickIntervalMs / 1000)
    internalState.tickCount = internalState.tickCount + 1
    
    -- Ensure manual override is set
    if not ensureManualOverride() then
        return
    end
    
    -- Get current time of day
    local TimeOfDay = getTimeOfDay()

    local tod = nil
    if TimeOfDay and TimeOfDay.GetCurrentTOD then
        tod = TimeOfDay.GetCurrentTOD()
    end
    
    if not tod then
        tod = 1200  -- Default to noon if unavailable
    end
    
    -- Morning profile state tracking
    local mFactor = getMorningFactor(tod)
    if mFactor > 0.001 then
        internalState.morningWasActive = true
    elseif internalState.morningWasActive then
        internalState.morningWasActive = false
        -- Re-randomize mood after morning ends
        if Config.CloudsFog.ReRandomizeAfterMorning then
            internalState.moodTarget = (math.random() * 2.0 - 1.0)
            Log.Debug(MODULE, "Morning ended, new mood", {mood = internalState.moodTarget})
        end
    end
    
    -- Check for new day (TOD wrapped)
    local lastTOD = State.GetLastKnownTOD() or tod
    if tod < lastTOD - 100 then  -- Wrapped from ~2400 to ~0
        internalState.moodTarget = (math.random() * 2.0 - 1.0)
        if Config.CloudsFog.MorningProfilesEnabled then
            internalState.morningProfile = pickMorningProfile()
            Log.Info(MODULE, "New day", {morningProfile = internalState.morningProfile})
        end
    end
    
    -- Smooth mood transition
    internalState.moodCurrent = Utils.ExpSmooth(
        internalState.moodCurrent,
        internalState.moodTarget,
        Config.CloudsFog.MoodSmoothingSeconds,
        dt
    )
    
    -- Check if a weather preset is overriding values
    local presetCloud = State.GetPresetCloudTarget()
    local presetFog = State.GetPresetFogTarget()
    local presetActive = State.IsPresetActive()
    
    -- Update clouds
    if Config.CloudsFog.CloudAutoEnabled then
        local targetCloud
        
        if presetActive and presetCloud ~= nil then
            -- Use preset value directly
            targetCloud = presetCloud
        else
            -- Calculate automatic value
            targetCloud = CloudsFog.TargetCloudCoverage(tod)
        end
        
        -- Initialize current value if needed
        if internalState.cloudCurrent == nil then
            internalState.cloudCurrent = CloudsFog.GetCloudCoverage() or targetCloud
        end
        
        -- Apply smoothing (skip when preset active for immediate response)
        local newCloud
        if presetActive then
            newCloud = targetCloud
        else
            newCloud = Utils.ExpSmooth(
                internalState.cloudCurrent,
                targetCloud,
                Config.CloudsFog.CloudSmoothingSeconds,
                dt
            )
        end
        
        writeCloudCoverage(newCloud)
        internalState.cloudCurrent = newCloud
    end
    
    -- Update fog
    if Config.CloudsFog.FogAutoEnabled then
        local targetFog
        
        if presetActive and presetFog ~= nil then
            -- Use preset value directly
            targetFog = presetFog
        else
            -- Calculate automatic value
            targetFog = CloudsFog.TargetFog(tod)
        end
        
        -- Initialize current value if needed
        if internalState.fogCurrent == nil then
            internalState.fogCurrent = CloudsFog.GetFog() or targetFog
        end
        
        -- Apply smoothing (skip when preset active for immediate response)
        local newFog
        if presetActive then
            newFog = targetFog
        else
            newFog = Utils.ExpSmooth(
                internalState.fogCurrent,
                targetFog,
                Config.CloudsFog.FogSmoothingSeconds,
                dt
            )
        end
        
        writeFog(newFog)
        internalState.fogCurrent = newFog
    end
    
    -- Debug logging (first few ticks only)
    if internalState.tickCount <= 3 then
        Log.Debug(MODULE, "Tick", {
            tod = tod,
            cloud = internalState.cloudCurrent,
            fog = internalState.fogCurrent,
            presetActive = presetActive
        })
    end
end

--- Get current status for debugging
--- @return table
function CloudsFog.GetStatus()
    return {
        enabled = Config.CloudsFog.Enabled,
        cloudCurrent = internalState.cloudCurrent,
        fogCurrent = internalState.fogCurrent,
        morningProfile = internalState.morningProfile,
        mood = internalState.moodCurrent,
        manualOverrideSet = internalState.manualOverrideSet,
        tickCount = internalState.tickCount,
    }
end

--- Reset to defaults
function CloudsFog.Reset()
    internalState.cloudCurrent = nil
    internalState.fogCurrent = nil
    internalState.manualOverrideSet = false
    Log.Info(MODULE, "Reset")
end

--- Called when course loads
function CloudsFog.OnCourseLoad()
    internalState.manualOverrideSet = false
    ensureManualOverride()
end

--- Called when course unloads
function CloudsFog.OnCourseUnload()
    internalState.manualOverrideSet = false
end

-- Initialize on load
CloudsFog.Init()

return CloudsFog
