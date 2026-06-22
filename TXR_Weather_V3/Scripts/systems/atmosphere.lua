-- TXR Weather Mod v3.0
-- systems/atmosphere.lua
-- Phase 9: Atmospheric Enhancements (god rays, aurora, cloud shadows)

local Atmosphere = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil

local MODULE = "Atmosphere"

-- ============== CONFIGURATION ==============
-- Feature toggles (can be overridden in Config.Atmosphere)
local ENABLE_CLOUD_SHADOWS = true
local ENABLE_GOD_RAYS = true
local ENABLE_AURORA = true
local ENABLE_SECOND_CLOUD_LAYER = true

-- Aurora timing (TOD values)
local AURORA_NIGHT_START = 1950  -- 19:30 - aurora becomes visible
local AURORA_NIGHT_END = 550     -- 05:30 - aurora fades out
local AURORA_MAX_INTENSITY = 1.5

-- God rays cutoff (disable when too cloudy)
local GOD_RAYS_CLOUD_CUTOFF = 7.2  -- Disable god rays above this cloud coverage

-- Cloud shadows intensity
local CLOUD_SHADOWS_SUNNY = 0.7
local CLOUD_SHADOWS_OVERCAST = 0.3

-- Smoothing
local SMOOTHING_SPEED = 0.1  -- How fast to interpolate (0-1 per tick)

-- ============== UDS PROPERTY NAMES ==============
-- Aurora
local PROP_USE_AURORAS = "Use Auroras"
local PROP_AURORA_INTENSITY = "Aurora Intensity"
local PROP_AURORA_SPEED = "Aurora Speed"

-- Cloud Shadows
local PROP_USE_CLOUD_SHADOWS = "Use Cloud Shadows"
local PROP_CLOUD_SHADOWS_INTENSITY_SUNNY = "Cloud Shadows Intensity When Sunny"
local PROP_CLOUD_SHADOWS_INTENSITY_OVERCAST = "Cloud Shadows Intensity When Overcast"

-- God Rays (Light Shafts)
local PROP_USE_SUN_LIGHT_SHAFTS = "Use Sun Light Shafts"
local PROP_LIGHT_SHAFT_INTENSITY = "Light Shaft Intensity"

-- Second Cloud Layer
local PROP_USE_SECOND_CLOUD_LAYER = "Use Second Cloud Layer"
local PROP_SECOND_LAYER_OPACITY = "Second Cloud Layer Opacity"

-- ============== STATE ==============
local isInitialized = false
local currentAuroraIntensity = 0.0
local currentGodRayIntensity = 0.0
local targetAuroraIntensity = 0.0
local targetGodRayIntensity = 0.0

-- Cache what we last pushed to UDS so we can skip redundant per-tick writes
-- (and avoid reading "Use Auroras" back every tick).
local auroraOn = false
local lastGodRayWritten = nil
local lastAuroraWritten = nil

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

--- Read UDS property
local function readUDS(propName)
    local actors = getActors()
    if not actors then return nil end
    
    local uds = actors.GetUDS()
    if not uds then return nil end
    
    local value = nil
    pcall(function()
        value = uds[propName]
    end)
    return value
end

--- Write UDS property
local function writeUDS(propName, value)
    local actors = getActors()
    if not actors then return false end
    
    local uds = actors.GetUDS()
    if not uds then return false end
    
    local ok = pcall(function()
        uds[propName] = value
    end)
    return ok
end

--- Check if TOD is in night window for aurora
--- @param tod number
--- @return boolean
local function isAuroraNight(tod)
    -- Night wraps around midnight
    return tod >= AURORA_NIGHT_START or tod <= AURORA_NIGHT_END
end

--- Calculate aurora intensity based on TOD
--- @param tod number
--- @return number 0.0 to AURORA_MAX_INTENSITY
local function calculateAuroraIntensity(tod)
    if not isAuroraNight(tod) then
        return 0.0
    end
    
    -- Calculate how deep into night we are
    local nightDepth = 0.0
    
    if tod >= AURORA_NIGHT_START then
        -- Evening side: 1950 to 2400
        local progress = (tod - AURORA_NIGHT_START) / (2400 - AURORA_NIGHT_START)
        nightDepth = progress * 0.5  -- 0 to 0.5
    else
        -- Morning side: 0 to 550
        local progress = tod / AURORA_NIGHT_END
        nightDepth = 1.0 - (progress * 0.5)  -- 1.0 down to 0.5
    end
    
    -- Peak at midnight (TOD 0/2400)
    -- Smooth curve: use sine for natural fade
    local intensity = math.sin(nightDepth * math.pi) * AURORA_MAX_INTENSITY
    return math.max(0.0, intensity)
end

--- Calculate god ray intensity based on cloud coverage
--- @param cloudCoverage number 0-10
--- @return number 0.0 to 1.0
local function calculateGodRayIntensity(cloudCoverage)
    if cloudCoverage >= GOD_RAYS_CLOUD_CUTOFF then
        return 0.0
    end
    
    -- Fade out as clouds increase
    local fade = 1.0 - (cloudCoverage / GOD_RAYS_CLOUD_CUTOFF)
    return math.max(0.0, math.min(1.0, fade))
end

--- Lerp toward target value
local function smoothStep(current, target, speed)
    local diff = target - current
    if math.abs(diff) < 0.01 then
        return target
    end
    return current + diff * speed
end

-- ============== PUBLIC API ==============

--- Initialize atmosphere module
--- @return boolean success
function Atmosphere.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    Log.Info(MODULE, "Initializing atmosphere module")
    
    -- Read config overrides
    if Config.Atmosphere then
        if Config.Atmosphere.EnableCloudShadows ~= nil then
            ENABLE_CLOUD_SHADOWS = Config.Atmosphere.EnableCloudShadows
        end
        if Config.Atmosphere.EnableGodRays ~= nil then
            ENABLE_GOD_RAYS = Config.Atmosphere.EnableGodRays
        end
        if Config.Atmosphere.EnableAurora ~= nil then
            ENABLE_AURORA = Config.Atmosphere.EnableAurora
        end
        if Config.Atmosphere.EnableSecondCloudLayer ~= nil then
            ENABLE_SECOND_CLOUD_LAYER = Config.Atmosphere.EnableSecondCloudLayer
        end
        if Config.Atmosphere.Enabled == false then
            Log.Info(MODULE, "Atmosphere disabled in config")
            isInitialized = true
            return true
        end
    end
    
    isInitialized = true
    State.SetModuleStatus("atmosphere", true)
    
    return true
end

--- Apply initial atmosphere settings (call once when actors ready)
function Atmosphere.Setup()
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end
    
    -- Enable cloud shadows
    if ENABLE_CLOUD_SHADOWS then
        writeUDS(PROP_USE_CLOUD_SHADOWS, true)
        writeUDS(PROP_CLOUD_SHADOWS_INTENSITY_SUNNY, CLOUD_SHADOWS_SUNNY)
        writeUDS(PROP_CLOUD_SHADOWS_INTENSITY_OVERCAST, CLOUD_SHADOWS_OVERCAST)
        Log.Debug(MODULE, "Cloud shadows enabled")
    end
    
    -- Enable second cloud layer
    if ENABLE_SECOND_CLOUD_LAYER then
        writeUDS(PROP_USE_SECOND_CLOUD_LAYER, true)
        Log.Debug(MODULE, "Second cloud layer enabled")
    end
    
    -- God rays will be controlled dynamically based on clouds
    if ENABLE_GOD_RAYS then
        writeUDS(PROP_USE_SUN_LIGHT_SHAFTS, true)
        Log.Debug(MODULE, "God rays enabled")
    end
    
    -- Aurora starts disabled, will be controlled by time
    if ENABLE_AURORA then
        writeUDS(PROP_USE_AURORAS, false)
        writeUDS(PROP_AURORA_SPEED, 0.15)
        auroraOn = false
        Log.Debug(MODULE, "Aurora system ready")
    end

    -- Force the next tick to push fresh values
    lastGodRayWritten = nil
    lastAuroraWritten = nil
    
    Log.Info(MODULE, "Atmosphere setup complete")
end

--- Main tick function
function Atmosphere.Tick()
    if not isInitialized then return end
    if Config.Atmosphere and Config.Atmosphere.Enabled == false then return end
    
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end
    
    -- Don't run during PA
    if State.IsPAFrozen and State.IsPAFrozen() then return end
    
    local tod = getTimeOfDay()
    if not tod then return end
    
    local currentTOD = tod.GetCurrentTOD()
    if not currentTOD then return end
    
    -- Get current cloud coverage for god rays
    local udw = actors.GetUDW()
    local cloudCoverage = 0
    if udw then
        pcall(function()
            cloudCoverage = tonumber(udw["Cloud Coverage"]) or 0
        end)
    end
    
    -- Update Aurora
    if ENABLE_AURORA then
        targetAuroraIntensity = calculateAuroraIntensity(currentTOD)
        currentAuroraIntensity = smoothStep(currentAuroraIntensity, targetAuroraIntensity, SMOOTHING_SPEED)

        if currentAuroraIntensity > 0.01 then
            -- Use our cached on/off state instead of reading the property back each tick
            if not auroraOn then
                writeUDS(PROP_USE_AURORAS, true)
                auroraOn = true
                Log.Info(MODULE, "Aurora enabled", {tod = currentTOD})
            end
            -- Only write intensity when it actually moved
            if not lastAuroraWritten or math.abs(currentAuroraIntensity - lastAuroraWritten) > 0.005 then
                writeUDS(PROP_AURORA_INTENSITY, currentAuroraIntensity)
                lastAuroraWritten = currentAuroraIntensity
            end
        else
            if auroraOn then
                writeUDS(PROP_USE_AURORAS, false)
                auroraOn = false
                lastAuroraWritten = nil
                Log.Info(MODULE, "Aurora disabled", {tod = currentTOD})
            end
        end
    end

    -- Update God Rays based on cloud coverage
    if ENABLE_GOD_RAYS then
        targetGodRayIntensity = calculateGodRayIntensity(cloudCoverage)
        currentGodRayIntensity = smoothStep(currentGodRayIntensity, targetGodRayIntensity, SMOOTHING_SPEED)

        -- Skip the reflected-property write once the value has converged
        if not lastGodRayWritten or math.abs(currentGodRayIntensity - lastGodRayWritten) > 0.005 then
            writeUDS(PROP_LIGHT_SHAFT_INTENSITY, currentGodRayIntensity)
            lastGodRayWritten = currentGodRayIntensity
        end
    end
end

--- Get current aurora intensity
--- @return number
function Atmosphere.GetAuroraIntensity()
    return currentAuroraIntensity
end

--- Get current god ray intensity
--- @return number
function Atmosphere.GetGodRayIntensity()
    return currentGodRayIntensity
end

--- Check if aurora is currently active
--- @return boolean
function Atmosphere.IsAuroraActive()
    return currentAuroraIntensity > 0.01
end

--- Get status for debugging
--- @return table
function Atmosphere.GetStatus()
    return {
        initialized = isInitialized,
        auroraIntensity = currentAuroraIntensity,
        auroraTarget = targetAuroraIntensity,
        godRayIntensity = currentGodRayIntensity,
        godRayTarget = targetGodRayIntensity,
        cloudShadowsEnabled = ENABLE_CLOUD_SHADOWS,
        godRaysEnabled = ENABLE_GOD_RAYS,
        auroraEnabled = ENABLE_AURORA,
        secondCloudLayerEnabled = ENABLE_SECOND_CLOUD_LAYER,
    }
end

--- Check if module is initialized
--- @return boolean
function Atmosphere.IsInitialized()
    return isInitialized
end

return Atmosphere
