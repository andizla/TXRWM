-- TXR Weather Mod v3.0
-- systems/enhanced_fog.lua
-- Enhanced fog control that works with both UDW and UDS properties
-- Phase 7 Implementation
--
-- UDW's "Fog" property (0-10) only sets a weather state value; UDS computes
-- the real density from several multipliers, which this module drives.

local EnhancedFog = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local Actors = require("systems.actors")
local Config = require("config")

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
-- Enhanced fog presets for different fog intensities
-- Values tuned down; volumetric fog required for all presets for weather system
local FOG_PROFILES = {
    -- No fog (Clear_Skies)
    none = {
        scaleFogDensity = 0.25,
        baseFogDensity = 0.006,
        foggyDensityContribution = 0.12,
        useVolumetric = true,
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
        useVolumetric = true,
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
        useVolumetric = true,
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
        useVolumetric = true,
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
        useVolumetric = true,
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
    lastScaleDensity = nil,   -- current profile's scale (for the covered damp)
    stockHeightFogFalloff = nil,  -- course-stock falloff, captured on first apply
}

-- Covered-road fog damp: multiplier on Scale Fog Density while the tunnels
-- module reports the car under a roof (1.0 = off). Config.Tunnels.CoveredFogMult.
local coveredDamp = 1.0
local COVERED_FOG_MULT = 0.15

-- ============== INTERNAL FUNCTIONS ==============

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

    local successCount = 0
    local attemptCount = 0

    -- Scale fog density is the key multiplier. coveredDamp thins it on
    -- covered road (tunnels report in via SetCoveredDamp): global fog is
    -- blind to ceilings, so a foggy preset otherwise reads as a white wall
    -- inside every bore.
    if profile.scaleFogDensity then
        attemptCount = attemptCount + 1
        internalState.lastScaleDensity = profile.scaleFogDensity
        local ok = pcall(function()
            uds[UDS_PROPS.SCALE_FOG_DENSITY] = profile.scaleFogDensity * coveredDamp
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
    
    -- Height fog falloff: heavy/extreme lower it for taller fog; every other
    -- profile restores the course's stock value (captured before any write),
    -- so a foggy spell cannot leave its low falloff behind for the course.
    if internalState.stockHeightFogFalloff == nil then
        pcall(function()
            local v = uds[UDS_PROPS.FOGGY_HEIGHT_FOG_FALLOFF]
            if type(v) == "number" then internalState.stockHeightFogFalloff = v end
        end)
    end
    local falloff = profile.heightFogFalloff or internalState.stockHeightFogFalloff
    if falloff then
        pcall(function()
            uds[UDS_PROPS.FOGGY_HEIGHT_FOG_FALLOFF] = falloff
        end)
    end
    
    -- Apply time-of-day multipliers: the exposure pipeline brightens night
    -- scenes and washes out fog, so nighttime density gets a boost
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
    pcall(function()
        if Config.Tunnels and Config.Tunnels.CoveredFogMult then
            COVERED_FOG_MULT = Config.Tunnels.CoveredFogMult
        end
    end)
    return true
end

--- Covered-road fog damp (called by the tunnels module on cover changes;
--- game thread). Rescales the current profile's Scale Fog Density; the
--- weather state (UDW fog value) stays untouched.
--- @param on boolean car under a roof
function EnhancedFog.SetCoveredDamp(on)
    local target = on and COVERED_FOG_MULT or 1.0
    if target == coveredDamp then return end
    coveredDamp = target
    if not internalState.initialized then return end
    local scale = internalState.lastScaleDensity
    if not scale then return end
    local uds = Actors.GetUDS()
    if not uds then return end
    local ok = pcall(function()
        uds[UDS_PROPS.SCALE_FOG_DENSITY] = scale * coveredDamp
    end)
    if ok then
        Log.Info(MODULE, "Covered fog damp " .. (on and "ON" or "OFF"), {
            scale = string.format("%.3f", scale * coveredDamp),
        })
    end
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
    
    -- UDW's Fog value belongs to CloudsFog while that module is enabled (it
    -- ramps the value; a direct write here fought the ramp on every
    -- non-immediate apply). With CloudsFog off this is the only fog write.
    local udw = Actors.GetUDW()
    if udw then
        local cloudsFogOwns = Config.CloudsFog and Config.CloudsFog.Enabled ~= false
        pcall(function()
            if not cloudsFogOwns then udw[UDW_PROPS.FOG] = fogValue end
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

--- Called when course loads
function EnhancedFog.OnCourseLoad()
    internalState.manualOverrideSet = false
    -- Do not reset stockHeightFogFalloff here: main dispatches this after
    -- Persistence.Restore's weather apply, so a load into heavy fog has
    -- already captured true stock and a reset discarded it (the next
    -- mid-course capture then adopted 0.04 as stock for the rest of the
    -- course). OnCourseUnload resets it for the normal flow.
    -- The covered-road damp must not leak across worlds: unloading under a
    -- roof skips tunnels' exit edge, and a stale 0.0 here would zero Scale
    -- Fog Density for every preset all session.
    coveredDamp = 1.0
    -- Fog will be applied via Weather.Apply from persistence
end

--- Called when course unloads
function EnhancedFog.OnCourseUnload()
    internalState.manualOverrideSet = false
    internalState.stockHeightFogFalloff = nil
    coveredDamp = 1.0
end

-- Initialize on load
EnhancedFog.Init()

return EnhancedFog
