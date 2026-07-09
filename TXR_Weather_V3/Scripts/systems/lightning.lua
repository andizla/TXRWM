-- TXR Weather Mod v3.0
-- systems/lightning.lua
-- Lightning control using UDW's built-in Lightning Spawn Manager
-- Phase 7 Implementation

local Lightning = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local Actors = require("systems.actors")

local MODULE = "Lightning"

-- ============== PROPERTY NAMES ==============
local PROPS = {
    -- UDW Properties
    THUNDER_LIGHTNING = "Thunder/Lightning",
    THUNDER_MANUAL_OVERRIDE = "Thunder/Lightning - Manual Override",
    SPAWN_FLASHES = "Spawn Lightning Flashes",
    ENABLE_OBSCURED = "Enable Obscured Lightning",
    FLASH_FREQUENCY = "Lightning Flash Frequency",
    FLASH_MAX_INTENSITY = "Maximum Lightning Flash Light Intensity",
    FLASH_LIGHT_SOURCE = "Lightning Flash Light Source",
    FLASH_CAST_SHADOWS = "Lightning Flashes Cast Shadows",
    DAYTIME_INTENSITY = "Daytime Lightning Flash Intensity",
    NIGHTTIME_INTENSITY = "Nighttime Lightning Flash Intensity",
    LIGHTNING_MANAGER = "Lightning Spawn Manager",
    REFRESH_SETTINGS = "Refresh Settings",
}

-- ============== CONFIGURATION ==============
local DEFAULTS = {
    -- Threshold above which lightning should be active
    enableThreshold = 5.0,
    
    -- Default flash frequency (seconds between flashes)
    flashFrequency = 14.0,
    
    -- Default max intensity
    maxIntensity = 10.0,
    
    -- Enable light source effects
    lightSource = true,
    
    -- Enable obscured (in-cloud) lightning
    obscuredLightning = true,
}

-- ============== STATE ==============
local internalState = {
    initialized = false,
    lastThunderValue = 0,
    lightningEnabled = false,
    managerReference = nil,
}

-- ============== INTERNAL FUNCTIONS ==============

--- Enable manual override flags on UDW
--- @return boolean success
local function ensureManualOverride()
    local udw = Actors.GetUDW()
    if not udw then
        return false
    end
    
    local success = pcall(function()
        udw[PROPS.THUNDER_MANUAL_OVERRIDE] = true
    end)
    
    if success then
        Log.Debug(MODULE, "Thunder/Lightning manual override enabled")
    end
    
    return success
end

--- Get the Lightning Spawn Manager object from UDW
--- @return userdata|nil manager
local function getLightningManager()
    if internalState.managerReference then
        -- Validate cached reference
        if Utils.IsValidObject(internalState.managerReference) then
            return internalState.managerReference
        end
        internalState.managerReference = nil
    end
    
    local udw = Actors.GetUDW()
    if not udw then
        return nil
    end
    
    local manager = nil
    local success = pcall(function()
        manager = udw[PROPS.LIGHTNING_MANAGER]
    end)
    
    if success and manager and Utils.IsValidObject(manager) then
        internalState.managerReference = manager
        Log.Debug(MODULE, "Got Lightning Spawn Manager", {
            address = Utils.FormatAddress(manager)
        })
        return manager
    end
    
    return nil
end

--- Configure lightning flash properties
--- @param intensity number Lightning intensity (0-10)
local function configureLightningFlashes(intensity)
    local udw = Actors.GetUDW()
    if not udw then return end
    
    -- Enable flash spawning if intensity is high enough
    local enableFlashes = intensity >= DEFAULTS.enableThreshold
    
    pcall(function()
        udw[PROPS.SPAWN_FLASHES] = enableFlashes
    end)
    
    pcall(function()
        udw[PROPS.ENABLE_OBSCURED] = DEFAULTS.obscuredLightning
    end)
    
    pcall(function()
        udw[PROPS.FLASH_LIGHT_SOURCE] = DEFAULTS.lightSource
    end)
    
    -- Scale frequency inversely with intensity (more intense = more frequent)
    -- At intensity 10: frequency ~7s, at intensity 5: frequency ~14s
    if intensity > 0 then
        local scaledFrequency = DEFAULTS.flashFrequency * (10.0 / math.max(intensity, 1))
        scaledFrequency = Utils.Clamp(scaledFrequency, 5.0, 30.0)
        
        pcall(function()
            udw[PROPS.FLASH_FREQUENCY] = scaledFrequency
        end)
    end
    
    -- Scale max intensity with thunder value
    local scaledMaxIntensity = DEFAULTS.maxIntensity * (intensity / 10.0)
    pcall(function()
        udw[PROPS.FLASH_MAX_INTENSITY] = scaledMaxIntensity
    end)
    
    Log.Debug(MODULE, "Configured lightning flashes", {
        enabled = enableFlashes,
        intensity = intensity
    })
end

-- ============== PUBLIC API ==============

--- Initialize the lightning module
function Lightning.Init()
    Log.Info(MODULE, "Initializing lightning module")
    internalState.initialized = true
    internalState.lastThunderValue = 0
    internalState.lightningEnabled = false
    internalState.managerReference = nil
    return true
end

--- Set lightning/thunder intensity
--- @param intensity number Lightning intensity (0-10)
--- @return boolean success
function Lightning.SetIntensity(intensity)
    intensity = Utils.Clamp(intensity, 0, 10)
    
    if not ensureManualOverride() then
        Log.Warn(MODULE, "Failed to enable manual override")
        return false
    end
    
    local udw = Actors.GetUDW()
    if not udw then
        Log.Warn(MODULE, "No UDW actor available")
        return false
    end
    
    -- Set the thunder/lightning intensity
    local success = pcall(function()
        udw[PROPS.THUNDER_LIGHTNING] = intensity
    end)
    
    if not success then
        Log.Error(MODULE, "Failed to set Thunder/Lightning intensity")
        return false
    end
    
    -- Configure flash properties
    configureLightningFlashes(intensity)
    
    -- Trigger settings refresh
    pcall(function()
        udw[PROPS.REFRESH_SETTINGS] = true
    end)
    
    internalState.lastThunderValue = intensity
    internalState.lightningEnabled = intensity >= DEFAULTS.enableThreshold
    
    Log.Info(MODULE, "Set lightning intensity", {
        intensity = intensity,
        enabled = internalState.lightningEnabled
    })
    
    return true
end

--- Enable lightning with preset-defined intensity
--- @param presetData table|nil Preset data with thunderIntensity field
--- @return boolean success
function Lightning.EnableFromPreset(presetData)
    if not presetData then
        return Lightning.SetIntensity(0)
    end
    
    local intensity = presetData.thunderIntensity or 0
    
    -- If preset explicitly has lightning
    if presetData.hasLightning then
        intensity = math.max(intensity, 8.0)  -- Ensure minimum visibility
    end
    
    return Lightning.SetIntensity(intensity)
end

--- Disable lightning
--- @return boolean success
function Lightning.Disable()
    Log.Info(MODULE, "Disabling lightning")
    return Lightning.SetIntensity(0)
end

--- Check if lightning is currently enabled
--- @return boolean
function Lightning.IsEnabled()
    return internalState.lightningEnabled
end

--- Get current lightning intensity
--- @return number intensity (0-10)
function Lightning.GetIntensity()
    local udw = Actors.GetUDW()
    if not udw then
        return internalState.lastThunderValue
    end
    
    local value = nil
    local success = pcall(function()
        value = udw[PROPS.THUNDER_LIGHTNING]
    end)
    
    if success and value then
        return value
    end
    
    return internalState.lastThunderValue
end

--- Trigger a manual lightning flash (for testing/effects)
--- @param angle number|nil Flash angle in degrees (random if nil)
--- @return boolean success
function Lightning.TriggerFlash(angle)
    local udw = Actors.GetUDW()
    if not udw then
        return false
    end
    
    angle = angle or (math.random() * 360)
    
    -- Try to call Flash Lightning function
    local flashFn = nil
    local success = pcall(function()
        flashFn = udw["Flash Lightning"]
    end)
    
    if success and flashFn then
        local callSuccess = pcall(function()
            -- Flash Lightning(Self, Angle, UseCustomLocation, CustomLocation, CustomTarget, RandomSeed)
            flashFn(udw, angle, false, {X=0, Y=0, Z=0}, {X=0, Y=0, Z=0}, -1)
        end)
        
        if callSuccess then
            Log.Debug(MODULE, "Triggered manual lightning flash", {angle = angle})
            return true
        end
    end
    
    -- Fallback: Try Global Lightning Managed Spawn via the manager
    local manager = getLightningManager()
    if manager then
        local spawnFn = nil
        pcall(function()
            spawnFn = udw["Global Lightning Managed Spawn"]
        end)
        
        if spawnFn then
            local callSuccess = pcall(function()
                spawnFn(udw, angle, 0.0)  -- Angle, ThresholdIntensity
            end)
            if callSuccess then
                Log.Debug(MODULE, "Triggered lightning via manager", {angle = angle})
                return true
            end
        end
    end
    
    Log.Warn(MODULE, "Could not trigger lightning flash")
    return false
end

--- Tick function (called from main loop)
function Lightning.Tick()
    -- Lightning is managed by UDW's internal systems once enabled
    -- This tick can be used for any periodic adjustments if needed
end

--- Get status for debugging
--- @return table
function Lightning.GetStatus()
    return {
        initialized = internalState.initialized,
        enabled = internalState.lightningEnabled,
        lastIntensity = internalState.lastThunderValue,
        currentIntensity = Lightning.GetIntensity(),
        hasManager = getLightningManager() ~= nil,
    }
end

--- Reset lightning state
function Lightning.Reset()
    Lightning.Disable()
    internalState.managerReference = nil
    Log.Info(MODULE, "Reset")
end

--- Called when course loads
function Lightning.OnCourseLoad()
    internalState.managerReference = nil
    -- Lightning state will be restored via Weather.Apply from persistence
end

--- Called when course unloads
function Lightning.OnCourseUnload()
    internalState.managerReference = nil
    internalState.lightningEnabled = false
end

-- Initialize on load
Lightning.Init()

return Lightning
