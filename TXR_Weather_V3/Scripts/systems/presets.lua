-- TXR Weather Mod v3.0
-- systems/presets.lua
-- Weather preset definitions and asset path mapping

local Presets = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Config = require("config")

local MODULE = "Presets"

-- ============== CONSTANTS ==============

-- Base path for all weather preset assets
local PRESET_BASE_PATH = "/Game/UltraDynamicSky/Blueprints/Weather_Effects/Weather_Presets/"

-- ============== PRESET DEFINITIONS ==============
-- Maps friendly names to UDW asset names

local PRESET_DATA = {
    -- Clear/Sunny
    Clear_Skies = {
        assetName = "Clear_Skies",
        displayName = "Clear Skies",
        category = "clear",
        hasRain = false,
        hasSnow = false,
        cloudCoverage = 0.5,
        fog = 0.0,
    },
    
    -- Cloudy variants
    Partly_Cloudy = {
        assetName = "Partly_Cloudy",
        displayName = "Partly Cloudy",
        category = "cloudy",
        hasRain = false,
        hasSnow = false,
        cloudCoverage = 2.0,
        fog = 0.2,
    },
    Cloudy = {
        assetName = "Cloudy",
        displayName = "Cloudy",
        category = "cloudy",
        hasRain = false,
        hasSnow = false,
        cloudCoverage = 4.0,
        fog = 0.4,
    },
    Overcast = {
        assetName = "Overcast",
        displayName = "Overcast",
        category = "cloudy",
        hasRain = false,
        hasSnow = false,
        cloudCoverage = 6.0,
        fog = 0.6,
        -- Cool the deck down: the session grade (saturation 1.15, warm
        -- absorption boost) reads too warm under full cloud (user
        -- 2026-07-15 "overcast needs to be more overcasty")
        skyGrade = {
            ["Saturation"] = 1.0,
            ["Desaturate Rayleigh Scattering When Cloudy"] = 0.55,
            ["Volumetric Cloud Ambient Light Saturation"] = 0.38,
            ["Sunset/Sunrise Color Intensity (Absorption Scale)"] = 0.0020,
        },
    },
    -- Heavy overcast (user request 2026-07-15): a proper grey deck, denser
    -- than Overcast, desaturated hard but not greyscale. Reuses the game's
    -- Overcast asset; the difference is our overlay + grade.
    Overcast_Heavy = {
        assetName = "Overcast",
        displayName = "Heavy Overcast",
        category = "cloudy",
        hasRain = false,
        hasSnow = false,
        cloudCoverage = 7.5,
        fog = 0.9,
        skyGrade = {
            ["Saturation"] = 0.88,
            ["Desaturate Rayleigh Scattering When Cloudy"] = 0.75,
            ["Volumetric Cloud Ambient Light Saturation"] = 0.25,
            ["Sunset/Sunrise Color Intensity (Absorption Scale)"] = 0.0012,
        },
    },
    
    -- Fog
    Foggy = {
        assetName = "Foggy",
        displayName = "Foggy",
        category = "fog",
        hasRain = false,
        hasSnow = false,
        cloudCoverage = 3.0,
        fog = 5.0,  -- Increased for EnhancedFog system (Phase 7)
    },
    
    -- Rain variants (intensity values from UDS preset JSON files)
    Rain_Light = {
        assetName = "Rain_Light",
        displayName = "Light Rain",
        category = "rain",
        hasRain = true,
        hasSnow = false,
        rainIntensity = 5.0,
        thunderIntensity = 0.0,  -- light rain carries NO thunder (2026-07-15)
        spawnCount = 10000.0,
        cloudCoverage = 5.0,
        fog = 0.8,
        skyGrade = {
            ["Saturation"] = 1.0,
            ["Desaturate Rayleigh Scattering When Cloudy"] = 0.55,
            ["Volumetric Cloud Ambient Light Saturation"] = 0.38,
            ["Sunset/Sunrise Color Intensity (Absorption Scale)"] = 0.0018,
        },
    },
    Rain = {
        assetName = "Rain",
        displayName = "Rain",
        category = "rain",
        hasRain = true,
        hasSnow = false,
        rainIntensity = 7.0,
        thunderIntensity = 4.0,  -- below Audio.CloseThunderMin: distant only
        spawnCount = 20000.0,
        cloudCoverage = 6.0,
        fog = 1.0,
        skyGrade = {
            ["Saturation"] = 0.95,
            ["Desaturate Rayleigh Scattering When Cloudy"] = 0.60,
            ["Volumetric Cloud Ambient Light Saturation"] = 0.33,
            ["Sunset/Sunrise Color Intensity (Absorption Scale)"] = 0.0016,
        },
    },
    Rain_Thunderstorm = {
        assetName = "Rain_Thunderstorm",
        displayName = "Thunderstorm",
        category = "rain",
        hasRain = true,
        hasSnow = false,
        hasLightning = true,
        rainIntensity = 10.0,
        thunderIntensity = 10.0,
        spawnCount = 25000.0,
        cloudCoverage = 8.0,
        fog = 1.5,
        skyGrade = {
            ["Saturation"] = 0.92,
            ["Desaturate Rayleigh Scattering When Cloudy"] = 0.65,
            ["Volumetric Cloud Ambient Light Saturation"] = 0.30,
            ["Sunset/Sunrise Color Intensity (Absorption Scale)"] = 0.0014,
        },
    },
    
    -- Snow variants
    Snow_Light = {
        assetName = "Snow_Light",
        displayName = "Light Snow",
        category = "snow",
        hasRain = false,
        hasSnow = true,
        snowIntensity = 5.0,
        spawnCount = 10000.0,
        cloudCoverage = 4.0,
        fog = 0.5,
    },
    Snow = {
        assetName = "Snow",
        displayName = "Snow",
        category = "snow",
        hasRain = false,
        hasSnow = true,
        snowIntensity = 7.0,
        spawnCount = 20000.0,
        cloudCoverage = 5.5,
        fog = 0.8,
    },
    Snow_Blizzard = {
        assetName = "Snow_Blizzard",
        displayName = "Blizzard",
        category = "snow",
        hasRain = false,
        hasSnow = true,
        snowIntensity = 10.0,
        spawnCount = 25000.0,
        cloudCoverage = 7.0,
        fog = 6.0,  -- Increased for EnhancedFog system (Phase 7)
    },
    
    -- Sand/Dust variants
    Sand_Dust_Calm = {
        assetName = "Sand_Dust_Calm",
        displayName = "Dusty",
        category = "dust",
        hasRain = false,
        hasSnow = false,
        hasDust = true,
        dustIntensity = 5.0,
        spawnCount = 10000.0,
        cloudCoverage = 2.0,
        fog = 1.0,
    },
    Sand_Dust_Storm = {
        assetName = "Sand_Dust_Storm",
        displayName = "Dust Storm",
        category = "dust",
        hasRain = false,
        hasSnow = false,
        hasDust = true,
        dustIntensity = 10.0,
        spawnCount = 25000.0,
        cloudCoverage = 4.0,
        fog = 6.0,  -- Increased for EnhancedFog system (Phase 7)
    },
}

-- Ordered list for cycling (subset most relevant for TXR)
local DEFAULT_CYCLE_ORDER = {
    "Clear_Skies",
    "Partly_Cloudy",
    "Cloudy",
    "Overcast",
    "Overcast_Heavy",
    "Foggy",
    "Rain_Light",
    "Rain",
    "Rain_Thunderstorm",
}

-- ============== INTERNAL FUNCTIONS ==============

--- Build full asset path for a preset
--- @param assetName string The asset name (e.g., "Clear_Skies")
--- @return string Full asset path
local function buildAssetPath(assetName)
    -- Format: /Game/.../Weather_Presets/Name.Name
    return PRESET_BASE_PATH .. assetName .. "." .. assetName
end

-- ============== PUBLIC API ==============

--- Initialize presets module
function Presets.Init()
    Log.Info(MODULE, "Initializing presets module", {count = Presets.GetCount()})
    return true
end

--- Get preset data by name
--- @param presetName string Preset name (e.g., "Clear_Skies")
--- @return table|nil Preset data or nil if not found
function Presets.Get(presetName)
    return PRESET_DATA[presetName]
end

--- Get full asset path for a preset
--- @param presetName string Preset name
--- @return string|nil Asset path or nil if preset not found
function Presets.GetAssetPath(presetName)
    local data = PRESET_DATA[presetName]
    if not data then
        Log.Warn(MODULE, "Unknown preset requested", {name = presetName})
        return nil
    end
    return buildAssetPath(data.assetName)
end

--- Check if a preset exists
--- @param presetName string
--- @return boolean
function Presets.Exists(presetName)
    return PRESET_DATA[presetName] ~= nil
end

--- Get display name for a preset
--- @param presetName string
--- @return string
function Presets.GetDisplayName(presetName)
    local data = PRESET_DATA[presetName]
    if data then
        return data.displayName
    end
    return presetName
end

--- Check if preset has rain
--- @param presetName string
--- @return boolean
function Presets.HasRain(presetName)
    local data = PRESET_DATA[presetName]
    return data and data.hasRain or false
end

--- Check if preset has snow
--- @param presetName string
--- @return boolean
function Presets.HasSnow(presetName)
    local data = PRESET_DATA[presetName]
    return data and data.hasSnow or false
end

--- Check if preset is a "dry" preset (no precipitation)
--- @param presetName string
--- @return boolean
function Presets.IsDry(presetName)
    local data = PRESET_DATA[presetName]
    if not data then return true end
    return not data.hasRain and not data.hasSnow and not data.hasDust
end

--- Get list of all preset names
--- @return table Array of preset names
function Presets.GetAllNames()
    local names = {}
    for name, _ in pairs(PRESET_DATA) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--- Get count of available presets
--- @return number
function Presets.GetCount()
    local count = 0
    for _, _ in pairs(PRESET_DATA) do
        count = count + 1
    end
    return count
end

--- Get the cycle order (for keybind cycling)
--- @return table Array of preset names in cycle order
function Presets.GetCycleOrder()
    -- Use config if available, otherwise default
    if Config.Weather and Config.Weather.PresetCycleOrder then
        return Config.Weather.PresetCycleOrder
    end
    return DEFAULT_CYCLE_ORDER
end

--- Get next preset in cycle
--- @param currentPreset string|nil Current preset name
--- @return string Next preset name
function Presets.GetNextInCycle(currentPreset)
    local order = Presets.GetCycleOrder()
    
    if not currentPreset then
        return order[1]
    end
    
    for i, name in ipairs(order) do
        if name == currentPreset then
            local nextIndex = i + 1
            if nextIndex > #order then
                nextIndex = 1
            end
            return order[nextIndex]
        end
    end
    
    -- Current not in cycle, return first
    return order[1]
end

--- Get previous preset in cycle
--- @param currentPreset string|nil Current preset name
--- @return string Previous preset name
function Presets.GetPrevInCycle(currentPreset)
    local order = Presets.GetCycleOrder()
    
    if not currentPreset then
        return order[#order]
    end
    
    for i, name in ipairs(order) do
        if name == currentPreset then
            local prevIndex = i - 1
            if prevIndex < 1 then
                prevIndex = #order
            end
            return order[prevIndex]
        end
    end
    
    -- Current not in cycle, return last
    return order[#order]
end

--- Get presets by category
--- @param category string "clear", "cloudy", "fog", "rain", "snow", "dust"
--- @return table Array of preset names
function Presets.GetByCategory(category)
    local results = {}
    for name, data in pairs(PRESET_DATA) do
        if data.category == category then
            table.insert(results, name)
        end
    end
    return results
end

--- Get default preset name
--- @return string
function Presets.GetDefault()
    if Config.Weather and Config.Weather.DefaultPreset then
        return Config.Weather.DefaultPreset
    end
    return "Clear_Skies"
end

-- Log available presets on load
Log.Debug(MODULE, "Presets available", {count = Presets.GetCount()})

return Presets
