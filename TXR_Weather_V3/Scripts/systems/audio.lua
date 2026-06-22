-- TXR Weather Mod v3.0
-- systems/audio.lua
-- Phase 10: Weather audio control (rain, wind, thunder)

local Audio = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-load to avoid circular dependencies
local Actors = nil

local MODULE = "Audio"

-- ============== CONFIGURATION ==============
local ENABLE_RAIN_AUDIO = true
local ENABLE_WIND_AUDIO = true
local ENABLE_THUNDER_AUDIO = true

-- Volume scaling
local RAIN_VOLUME_SCALE = 1.0
local WIND_VOLUME_SCALE = 0.8
local THUNDER_VOLUME_SCALE = 1.0

-- ============== UDW AUDIO PROPERTIES ==============
local PROP_WEATHER_SOUNDS_VOLUME = "Weather Sounds Volume"
local PROP_RAIN_SOUNDS_VOLUME = "Rain Sounds Volume"
local PROP_WIND_SOUNDS_VOLUME = "Wind Sounds Volume"
local PROP_THUNDER_SOUNDS_VOLUME = "Thunder Sounds Volume"
local PROP_USE_WEATHER_SOUNDS = "Use Weather Sounds"

-- ============== STATE ==============
local isInitialized = false
local audioEnabled = true

-- ============== INTERNAL FUNCTIONS ==============

local function getActors()
    if not Actors then
        local success, mod = pcall(require, "systems.actors")
        if success then Actors = mod end
    end
    return Actors
end

--- Write UDW property
local function writeUDW(propName, value)
    local actors = getActors()
    if not actors then return false end
    
    local udw = actors.GetUDW()
    if not udw then return false end
    
    local ok = pcall(function()
        udw[propName] = value
    end)
    return ok
end

--- Read UDW property
local function readUDW(propName)
    local actors = getActors()
    if not actors then return nil end
    
    local udw = actors.GetUDW()
    if not udw then return nil end
    
    local value = nil
    pcall(function()
        value = udw[propName]
    end)
    return value
end

-- ============== PUBLIC API ==============

--- Initialize audio module
--- @return boolean success
function Audio.Init()
    if isInitialized then
        Log.Warn(MODULE, "Already initialized")
        return true
    end
    
    Log.Info(MODULE, "Initializing audio module")
    
    -- Read config
    if Config.Audio then
        if Config.Audio.EnableRain ~= nil then
            ENABLE_RAIN_AUDIO = Config.Audio.EnableRain
        end
        if Config.Audio.EnableWind ~= nil then
            ENABLE_WIND_AUDIO = Config.Audio.EnableWind
        end
        if Config.Audio.EnableThunder ~= nil then
            ENABLE_THUNDER_AUDIO = Config.Audio.EnableThunder
        end
        if Config.Audio.RainVolume then
            RAIN_VOLUME_SCALE = Config.Audio.RainVolume
        end
        if Config.Audio.WindVolume then
            WIND_VOLUME_SCALE = Config.Audio.WindVolume
        end
        if Config.Audio.ThunderVolume then
            THUNDER_VOLUME_SCALE = Config.Audio.ThunderVolume
        end
        if Config.Audio.Enabled == false then
            Log.Info(MODULE, "Audio module disabled in config")
            audioEnabled = false
        end
    end
    
    isInitialized = true
    State.SetModuleStatus("audio", true)
    
    return true
end

--- Setup audio (call once when actors ready)
function Audio.Setup()
    local actors = getActors()
    if not actors or not actors.IsOnCourse() then return end
    
    if not audioEnabled then
        -- Disable all weather sounds
        writeUDW(PROP_USE_WEATHER_SOUNDS, false)
        Log.Info(MODULE, "Weather sounds disabled")
        return
    end
    
    -- Enable weather sounds
    writeUDW(PROP_USE_WEATHER_SOUNDS, true)
    
    -- Set volume levels
    writeUDW(PROP_WEATHER_SOUNDS_VOLUME, 1.0)
    
    if ENABLE_RAIN_AUDIO then
        writeUDW(PROP_RAIN_SOUNDS_VOLUME, RAIN_VOLUME_SCALE)
    else
        writeUDW(PROP_RAIN_SOUNDS_VOLUME, 0.0)
    end
    
    if ENABLE_WIND_AUDIO then
        writeUDW(PROP_WIND_SOUNDS_VOLUME, WIND_VOLUME_SCALE)
    else
        writeUDW(PROP_WIND_SOUNDS_VOLUME, 0.0)
    end
    
    if ENABLE_THUNDER_AUDIO then
        writeUDW(PROP_THUNDER_SOUNDS_VOLUME, THUNDER_VOLUME_SCALE)
    else
        writeUDW(PROP_THUNDER_SOUNDS_VOLUME, 0.0)
    end
    
    Log.Info(MODULE, "Audio setup complete", {
        rain = ENABLE_RAIN_AUDIO and RAIN_VOLUME_SCALE or 0,
        wind = ENABLE_WIND_AUDIO and WIND_VOLUME_SCALE or 0,
        thunder = ENABLE_THUNDER_AUDIO and THUNDER_VOLUME_SCALE or 0,
    })
end

--- Toggle all weather audio
--- @return boolean newState
function Audio.Toggle()
    audioEnabled = not audioEnabled
    
    if audioEnabled then
        Audio.Setup()
    else
        writeUDW(PROP_USE_WEATHER_SOUNDS, false)
    end
    
    Log.Info(MODULE, "Audio toggled", {enabled = audioEnabled})
    return audioEnabled
end

--- Set rain volume
--- @param volume number 0.0-1.0
function Audio.SetRainVolume(volume)
    RAIN_VOLUME_SCALE = math.max(0.0, math.min(1.0, volume))
    if audioEnabled and ENABLE_RAIN_AUDIO then
        writeUDW(PROP_RAIN_SOUNDS_VOLUME, RAIN_VOLUME_SCALE)
    end
end

--- Set wind volume
--- @param volume number 0.0-1.0
function Audio.SetWindVolume(volume)
    WIND_VOLUME_SCALE = math.max(0.0, math.min(1.0, volume))
    if audioEnabled and ENABLE_WIND_AUDIO then
        writeUDW(PROP_WIND_SOUNDS_VOLUME, WIND_VOLUME_SCALE)
    end
end

--- Set thunder volume
--- @param volume number 0.0-1.0
function Audio.SetThunderVolume(volume)
    THUNDER_VOLUME_SCALE = math.max(0.0, math.min(1.0, volume))
    if audioEnabled and ENABLE_THUNDER_AUDIO then
        writeUDW(PROP_THUNDER_SOUNDS_VOLUME, THUNDER_VOLUME_SCALE)
    end
end

--- Check if audio is enabled
--- @return boolean
function Audio.IsEnabled()
    return audioEnabled
end

--- Get status for debugging
--- @return table
function Audio.GetStatus()
    return {
        initialized = isInitialized,
        enabled = audioEnabled,
        rainEnabled = ENABLE_RAIN_AUDIO,
        windEnabled = ENABLE_WIND_AUDIO,
        thunderEnabled = ENABLE_THUNDER_AUDIO,
        rainVolume = RAIN_VOLUME_SCALE,
        windVolume = WIND_VOLUME_SCALE,
        thunderVolume = THUNDER_VOLUME_SCALE,
    }
end

return Audio
