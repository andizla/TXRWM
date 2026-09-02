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
    -- At intensity 10: frequency ~14s, at intensity 5: frequency ~28s
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

--- Called when course loads
function Lightning.OnCourseLoad()
    -- Lightning state will be restored via Weather.Apply from persistence
end

--- Called when course unloads
function Lightning.OnCourseUnload()
    internalState.lightningEnabled = false
end

-- Initialize on load
Lightning.Init()

return Lightning
