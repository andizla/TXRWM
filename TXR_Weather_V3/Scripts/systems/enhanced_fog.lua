-- TXR Weather Mod v3.0
-- systems/enhanced_fog.lua
-- Enhanced fog control that works with both UDW and UDS properties
-- Phase 7 Implementation
--
-- The issue: UDW's "Fog" property (0-10) only sets a weather state value.
-- The actual fog density is computed by UDS using multiple multipliers.
-- This module controls the additional UDS properties to make fog visible.

local EnhancedFog = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local Actors = require("systems.actors")

local MODULE = "EnhancedFog"

-- ============== PROPERTY NAMES ==============
-- UDW Properties (weather state)
local UDW_PROPS = {
    FOG = "Fog",
    FOG_MANUAL_OVERRIDE = "Fog - Manual Override",
    REFRESH_SETTINGS = "Refresh Settings",
}

-- UDS Properties (rendering control)
local UDS_PROPS = {
    -- Primary density controls
    SCALE_FOG_DENSITY = "Scale Fog Density",
    BASE_FOG_DENSITY = "Base Fog Density",
    FOGGY_DENSITY_CONTRIBUTION = "Foggy Density Contribution",
    
    -- Volumetric fog
    USE_VOLUMETRIC_FOG = "Use Volumetric Fog",
    VOLUMETRIC_FOG_DISTANCE = "Volumetric Fog Distance",
    VOLUMETRIC_FOG_EXTINCTION = "Volumetric Fog Extinction",
    
    -- Height fog falloff
    BASE_HEIGHT_FOG_FALLOFF = "Base Height Fog Falloff",
    FOGGY_HEIGHT_FOG_FALLOFF = "Foggy Height Fog Falloff",
    
    -- Time-of-day multipliers
    FOG_DENSITY_DAYTIME_MULTIPLIER = "Fog Density Daytime Mutliplier",  -- Note: typo in UDS
    FOG_DENSITY_NIGHTTIME_MULTIPLIER = "Fog Density Nighttime Multiplier",
    
    -- Height fog control
    RENDER_EXPONENTIAL_HEIGHT_FOG = "Render Exponential Height Fog",
    
    -- Fog start distance (for clear weather)
    FOG_START_DISTANCE_WHEN_CLEAR = "Fog Start Distance When Clear",
}

-- ============== CONFIGURATION ==============
-- (Unused BASELINE defaults table removed 2026-07-09 - the profiles below
-- are the only values ever applied.)

-- Enhanced fog presets for different fog intensities
-- Values tuned down - volumetric fog required for all presets for weather system
local FOG_PROFILES = {
    -- No fog (Clear_Skies)
    none = {
        scaleFogDensity = 0.25,
        baseFogDensity = 0.006,
        foggyDensityContribution = 0.12,
        useVolumetric = true,  -- Required for weather system
        volumetricDistance = 9000.0,
        volumetricExtinction = 0.8,
        daytimeMultiplier = 1.0,
        nighttimeMultiplier = 1.0,
    },
    
    -- Light haze (Partly_Cloudy)
    light = {
        scaleFogDensity = 0.5,
        baseFogDensity = 0.008,
        foggyDensityContribution = 0.2,
        useVolumetric = true,  -- Required for weather system
        volumetricDistance = 8000.0,
        volumetricExtinction = 1.2,
        daytimeMultiplier = 1.0,
        nighttimeMultiplier = 1.4,
    },
    
    -- Medium fog (Overcast, Rain)
    medium = {
        scaleFogDensity = 0.8,
        baseFogDensity = 0.01,
        foggyDensityContribution = 0.35,
        useVolumetric = true,  -- Required for weather system
        volumetricDistance = 7000.0,
        volumetricExtinction = 1.6,
        daytimeMultiplier = 1.0,
        nighttimeMultiplier = 1.7,
    },
    
    -- Heavy fog (Foggy preset)
    heavy = {
        scaleFogDensity = 1.5,
        baseFogDensity = 0.016,
        foggyDensityContribution = 0.55,
        useVolumetric = true,  -- Required for weather system
        volumetricDistance = 5500.0,
        volumetricExtinction = 2.2,
        heightFogFalloff = 0.04,
        daytimeMultiplier = 1.0,
        nighttimeMultiplier = 2.0,
    },
    
    -- Very heavy fog (Blizzard, Dust Storm)
    extreme = {
        scaleFogDensity = 2.2,
        baseFogDensity = 0.024,
        foggyDensityContribution = 0.75,
        useVolumetric = true,  -- Required for weather system
        volumetricDistance = 4500.0,
        volumetricExtinction = 3.0,
        heightFogFalloff = 0.025,
        daytimeMultiplier = 1.0,
        nighttimeMultiplier = 2.3,
    },
}

-- ============== STATE ==============
local internalState = {
    initialized = false,
    currentProfile = "none",
    manualOverrideSet = false,
    
    -- Store original values for restoration
    originalValues = {},
    valuesStored = false,
}

-- ============== INTERNAL FUNCTIONS ==============

--- Store original UDS fog values for later restoration
local function storeOriginalValues()
    if internalState.valuesStored then
        return
    end
    
    local uds = Actors.GetUDS()
    if not uds then
        return
    end
    
    local props = {
        "Scale Fog Density",
        "Base Fog Density",
        "Foggy Density Contribution",
        "Use Volumetric Fog",
    }
    
    for _, prop in ipairs(props) do
        local value = nil
        pcall(function()
            value = uds[prop]
        end)
        if value ~= nil then
            internalState.originalValues[prop] = value
        end
    end
    
    internalState.valuesStored = true
    Log.Debug(MODULE, "Stored original fog values", internalState.originalValues)
end

--- Ensure UDW manual override is set
local function ensureManualOverride()
    if internalState.manualOverrideSet then
        return true
    end
    
    local udw = Actors.GetUDW()
    if not udw then
        return false
    end
    
    local success = pcall(function()
        udw[UDW_PROPS.FOG_MANUAL_OVERRIDE] = true
    end)
    
    if success then
        internalState.manualOverrideSet = true
        Log.Debug(MODULE, "Fog manual override enabled")
    end
    
    return success
end

--- Apply a fog profile to UDS
--- @param profile table Fog profile settings
--- @return boolean success
local function applyFogProfile(profile)
    local uds = Actors.GetUDS()
    if not uds then
        Log.Warn(MODULE, "No UDS actor for fog profile")
        return false
    end
    
    storeOriginalValues()
    
    local successCount = 0
    local attemptCount = 0
    
    -- Apply scale fog density (the key multiplier!)
    if profile.scaleFogDensity then
        attemptCount = attemptCount + 1
        local ok = pcall(function()
            uds[UDS_PROPS.SCALE_FOG_DENSITY] = profile.scaleFogDensity
        end)
        if ok then successCount = successCount + 1 end
    end
    
    -- Apply base fog density
    if profile.baseFogDensity then
        attemptCount = attemptCount + 1
        local ok = pcall(function()
            uds[UDS_PROPS.BASE_FOG_DENSITY] = profile.baseFogDensity
        end)
        if ok then successCount = successCount + 1 end
    end
    
    -- Apply foggy density contribution
    if profile.foggyDensityContribution then
        attemptCount = attemptCount + 1
        local ok = pcall(function()
            uds[UDS_PROPS.FOGGY_DENSITY_CONTRIBUTION] = profile.foggyDensityContribution
        end)
        if ok then successCount = successCount + 1 end
    end
    
    -- Apply volumetric fog settings
    if profile.useVolumetric ~= nil then
        attemptCount = attemptCount + 1
        local ok = pcall(function()
            uds[UDS_PROPS.USE_VOLUMETRIC_FOG] = profile.useVolumetric
        end)
        if ok then successCount = successCount + 1 end
    end
    
    if profile.volumetricDistance then
        pcall(function()
            uds[UDS_PROPS.VOLUMETRIC_FOG_DISTANCE] = profile.volumetricDistance
        end)
    end
    
    if profile.volumetricExtinction then
        pcall(function()
            uds[UDS_PROPS.VOLUMETRIC_FOG_EXTINCTION] = profile.volumetricExtinction
        end)
    end
    
    -- Apply height fog falloff
    if profile.heightFogFalloff then
        pcall(function()
            uds[UDS_PROPS.FOGGY_HEIGHT_FOG_FALLOFF] = profile.heightFogFalloff
        end)
    end
    
    -- Apply time-of-day multipliers (critical for VEAO compatibility)
    -- VEAO's auto-exposure washes out fog at night, so we boost nighttime density
    if profile.daytimeMultiplier then
        pcall(function()
            uds[UDS_PROPS.FOG_DENSITY_DAYTIME_MULTIPLIER] = profile.daytimeMultiplier
        end)
    end
    
    if profile.nighttimeMultiplier then
        pcall(function()
            uds[UDS_PROPS.FOG_DENSITY_NIGHTTIME_MULTIPLIER] = profile.nighttimeMultiplier
        end)
        Log.Debug(MODULE, "Set nighttime fog multiplier", {value = profile.nighttimeMultiplier})
    end
    
    Log.Debug(MODULE, "Applied fog profile", {
        profile = internalState.currentProfile,
        success = successCount,
        attempts = attemptCount,
        nightMult = profile.nighttimeMultiplier
    })
    
    return successCount > 0
end

--- Select appropriate fog profile based on fog value
--- @param fogValue number Fog intensity (0-10)
--- @return string profile name
local function selectProfile(fogValue)
    if fogValue <= 0.1 then
        return "none"
    elseif fogValue <= 1.0 then
        return "light"
    elseif fogValue <= 2.5 then
        return "medium"
    elseif fogValue <= 5.0 then
        return "heavy"
    else
        return "extreme"
    end
end

-- ============== PUBLIC API ==============

--- Initialize the enhanced fog module
function EnhancedFog.Init()
    Log.Info(MODULE, "Initializing enhanced fog module")
    internalState.initialized = true
    internalState.currentProfile = "none"
    internalState.manualOverrideSet = false
    internalState.valuesStored = false
    return true
end

--- Apply enhanced fog settings for a given fog intensity
--- @param fogValue number Fog intensity from preset (0-10)
--- @return boolean success
function EnhancedFog.Apply(fogValue)
    fogValue = Utils.Clamp(fogValue or 0, 0, 10)

    if not ensureManualOverride() then
        Log.Warn(MODULE, "Failed to set manual override")
    end
    
    -- Select and apply appropriate profile
    local profileName = selectProfile(fogValue)
    local profile = FOG_PROFILES[profileName]
    
    if not profile then
        Log.Error(MODULE, "Unknown fog profile", {name = profileName})
        return false
    end
    
    internalState.currentProfile = profileName
    
    local success = applyFogProfile(profile)
    
    if success then
        Log.Info(MODULE, "Applied enhanced fog", {
            fogValue = fogValue,
            profile = profileName,
            scaleDensity = profile.scaleFogDensity
        })
    end
    
    -- Also set UDW fog value (handled by CloudsFog, but ensure it's set)
    local udw = Actors.GetUDW()
    if udw then
        pcall(function()
            udw[UDW_PROPS.FOG] = fogValue
            udw[UDW_PROPS.REFRESH_SETTINGS] = true
        end)
    end
    
    return success
end

--- Apply fog settings from a weather preset
--- @param presetData table Preset data with fog field
--- @return boolean success
function EnhancedFog.ApplyFromPreset(presetData)
    if not presetData then
        return EnhancedFog.Apply(0)
    end
    
    local fogValue = presetData.fog or 0
    
    -- Special handling for specific preset categories
    if presetData.category == "fog" then
        -- Foggy presets need extra boost
        fogValue = math.max(fogValue, 5.0)
    elseif presetData.category == "snow" and presetData.assetName == "Snow_Blizzard" then
        -- Blizzard gets extreme profile
        fogValue = math.max(fogValue, 6.0)
    elseif presetData.category == "dust" and presetData.assetName == "Sand_Dust_Storm" then
        -- Dust storm gets extreme profile
        fogValue = math.max(fogValue, 6.0)
    end
    
    return EnhancedFog.Apply(fogValue)
end

--- Set a custom fog profile
--- @param profileName string Profile name: "none", "light", "medium", "heavy", "extreme"
--- @return boolean success
function EnhancedFog.SetProfile(profileName)
    local profile = FOG_PROFILES[profileName]
    if not profile then
        Log.Warn(MODULE, "Unknown profile", {name = profileName})
        return false
    end
    
    internalState.currentProfile = profileName
    return applyFogProfile(profile)
end

--- Get current fog profile name
--- @return string
function EnhancedFog.GetCurrentProfile()
    return internalState.currentProfile
end

--- Read current Scale Fog Density from UDS
--- @return number|nil
function EnhancedFog.GetScaleFogDensity()
    local uds = Actors.GetUDS()
    if not uds then
        return nil
    end
    
    local value = nil
    pcall(function()
        value = uds[UDS_PROPS.SCALE_FOG_DENSITY]
    end)
    return value
end

--- Set Scale Fog Density directly (for testing)
--- @param value number
--- @return boolean success
function EnhancedFog.SetScaleFogDensity(value)
    local uds = Actors.GetUDS()
    if not uds then
        return false
    end
    
    local success = pcall(function()
        uds[UDS_PROPS.SCALE_FOG_DENSITY] = value
    end)
    
    if success then
        Log.Info(MODULE, "Set Scale Fog Density", {value = value})
    end
    
    return success
end

--- Get fog debug info
--- @return table
function EnhancedFog.GetDebugInfo()
    local info = {
        currentProfile = internalState.currentProfile,
        manualOverrideSet = internalState.manualOverrideSet,
    }
    
    local uds = Actors.GetUDS()
    if uds then
        pcall(function()
            info.scaleFogDensity = uds[UDS_PROPS.SCALE_FOG_DENSITY]
        end)
        pcall(function()
            info.baseFogDensity = uds[UDS_PROPS.BASE_FOG_DENSITY]
        end)
        pcall(function()
            info.foggyDensityContribution = uds[UDS_PROPS.FOGGY_DENSITY_CONTRIBUTION]
        end)
        pcall(function()
            info.useVolumetricFog = uds[UDS_PROPS.USE_VOLUMETRIC_FOG]
        end)
    end
    
    local udw = Actors.GetUDW()
    if udw then
        pcall(function()
            info.udwFog = udw[UDW_PROPS.FOG]
        end)
    end
    
    return info
end

--- Get status for debugging
--- @return table
function EnhancedFog.GetStatus()
    return {
        initialized = internalState.initialized,
        currentProfile = internalState.currentProfile,
        scaleFogDensity = EnhancedFog.GetScaleFogDensity(),
        profiles = Utils.Keys(FOG_PROFILES),
    }
end

--- Reset to baseline fog settings
function EnhancedFog.Reset()
    -- Restore original values if we stored them
    if internalState.valuesStored then
        local uds = Actors.GetUDS()
        if uds then
            for prop, value in pairs(internalState.originalValues) do
                pcall(function()
                    uds[prop] = value
                end)
            end
            Log.Debug(MODULE, "Restored original fog values")
        end
    end
    
    internalState.currentProfile = "none"
    internalState.manualOverrideSet = false
    Log.Info(MODULE, "Reset")
end

--- Called when course loads
function EnhancedFog.OnCourseLoad()
    internalState.manualOverrideSet = false
    internalState.valuesStored = false
    -- Fog will be applied via Weather.Apply from persistence
end

--- Called when course unloads
function EnhancedFog.OnCourseUnload()
    internalState.manualOverrideSet = false
end

-- Initialize on load
EnhancedFog.Init()

return EnhancedFog
