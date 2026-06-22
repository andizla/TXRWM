-- TXR Weather Mod v3.0
-- systems/persistence.lua
-- Save and restore weather/time state between sessions
-- Uses V2's efficient key=value format

local Persistence = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Utils = require("core.utils")
local State = require("core.state")
local Config = require("config")

local MODULE = "Persistence"

-- ============== STATE ==============
local lastSaveTime = 0
local loadedData = nil

-- ============== FILE PATH ==============

local function getModRoot()
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local source = info.source:gsub("@", "")
        local root = source:match("(.+)[/\\]systems[/\\]") or ""
        if root ~= "" then
            root = root:match("(.+)[/\\]") or root
        end
        return root
    end
    return "."
end

local function getSaveFilePath()
    return getModRoot() .. "\\last_state.txt"
end

-- ============== SAVE ==============

function Persistence.Save(reason)
    if not Config.Persistence.Enabled then return false end
    
    -- Get actors
    local Actors = nil
    pcall(function() Actors = require("systems.actors") end)
    if not Actors then return false end
    
    local uds = Actors.GetUDS()
    local udw = Actors.GetUDW()
    
    -- Read live values
    local tod = -1
    if uds then
        pcall(function() tod = uds["Time Of Day"] end)
    end
    tod = Utils.ToNumber(tod, -1)
    
    local cloud = -1
    local fog = -1
    if udw then
        pcall(function() cloud = udw["Cloud Coverage"] end)
        pcall(function() fog = udw["Fog"] end)
    end
    cloud = Utils.ToNumber(cloud, -1)
    fog = Utils.ToNumber(fog, -1)
    
    -- CRITICAL: Don't save invalid values - they corrupt the file for next session
    if tod < 0 or tod > 2400 then
        Log.Debug(MODULE, string.format("Skipping save (%s) - invalid TOD: %.2f", reason or "auto", tod))
        -- Still update lastSaveTime to prevent spam retries
        lastSaveTime = os.time()
        return false
    end
    
    -- Write simple key=value format
    local f = io.open(getSaveFilePath(), "w")
    if f then
        local preset = State.GetCurrentPreset() or "Clear_Skies"
        
        -- Get wetness state if available
        local wetness, puddle = 0, 0
        pcall(function()
            local Wetness = require("systems.wetness")
            if Wetness and Wetness.GetState then
                local state = Wetness.GetState()
                wetness = state.wetness or 0
                puddle = state.puddleCoverage or 0
            end
        end)
        
        f:write(string.format(
            "tod=%.6f,cloud=%.6f,fog=%.6f,preset=%s,speed=%.6f,paused=%d,wetness=%.6f,puddle=%.6f\n",
            tod,
            cloud,
            fog,
            preset,
            State.GetTimeSpeed() or Config.TimeOfDay.DefaultSpeed,
            State.IsTimePaused() and 1 or 0,
            wetness,
            puddle
        ))
        f:close()
        lastSaveTime = os.time()
        Log.Debug(MODULE, string.format("State saved (%s): TOD=%.2f cloud=%.2f fog=%.2f preset=%s wetness=%.2f", 
            reason or "auto", tod, cloud, fog, preset, wetness))
        return true
    end
    return false
end

-- ============== LOAD ==============

--- Load state from file and return raw data (no side effects)
--- @return table|nil data with tod, cloud, fog, preset, speed, paused
function Persistence.LoadRaw()
    local f = io.open(getSaveFilePath(), "r")
    if not f then return nil end
    
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    
    -- Parse key=value pairs
    local data = {}
    for k, v in line:gmatch("([%w_]+)=([^,]+)") do
        local n = tonumber(v)
        if n then
            data[k] = n
        else
            data[k] = v
        end
    end
    
    return data
end

function Persistence.Load()
    if not Config.Persistence.Enabled then return nil end
    
    local data = Persistence.LoadRaw()
    if not data then return nil end
    
    if data.tod and data.tod >= 0 then
        loadedData = data
        Log.Info(MODULE, string.format("State loaded: TOD=%.2f cloud=%.2f fog=%.2f preset=%s",
            data.tod, data.cloud or -1, data.fog or -1, data.preset or "?"))
        return data
    end
    
    return nil
end

-- ============== RESTORE ==============

function Persistence.Restore()
    if not Config.Persistence.Enabled then return false end
    if not Config.Persistence.RestoreOnLoad then return false end
    
    -- ALWAYS read fresh from file, don't use cached startup data
    -- This is critical for PA transitions where we saved new state but cached data is stale
    local data = Persistence.LoadRaw()
    if not data then return false end
    
    local restored = false
    
    -- Restore TOD
    if data.tod and data.tod >= 0 then
        local TimeOfDay = nil
        pcall(function() TimeOfDay = require("systems.time_of_day") end)
        if TimeOfDay and TimeOfDay.SetTOD then
            TimeOfDay.SetTOD(data.tod)
            restored = true
            
            if data.speed then
                TimeOfDay.SetSpeed(data.speed)
            end
            if data.paused == 1 and TimeOfDay.Pause then
                TimeOfDay.Pause()
            end
        end
    end
    
    -- Restore cloud/fog
    if data.cloud and data.cloud >= 0 then
        local CloudsFog = nil
        pcall(function() CloudsFog = require("systems.clouds_fog") end)
        if CloudsFog and CloudsFog.SetCloudCoverage then
            CloudsFog.SetCloudCoverage(data.cloud, true)
            restored = true
        end
    end
    
    if data.fog and data.fog >= 0 then
        local CloudsFog = nil
        pcall(function() CloudsFog = require("systems.clouds_fog") end)
        if CloudsFog and CloudsFog.SetFog then
            CloudsFog.SetFog(data.fog, true)
            restored = true
        end
    end
    
    -- Restore preset
    if data.preset then
        local Weather = nil
        pcall(function() Weather = require("systems.weather") end)
        if Weather and Weather.Apply then
            Weather.Apply(data.preset, 1.0)
            restored = true
        end
    end
    
    -- Restore wetness state
    if data.wetness and data.wetness >= 0 then
        local Wetness = nil
        pcall(function() Wetness = require("systems.wetness") end)
        if Wetness and Wetness.SetLevels then
            Wetness.SetLevels(data.wetness, data.puddle or 0, 0)
            Log.Debug(MODULE, string.format("Restored wetness: %.3f puddle: %.3f", 
                data.wetness, data.puddle or 0))
            restored = true
        end
    end
    
    return restored
end

-- ============== TICK ==============

function Persistence.Tick()
    if not Config.Persistence.Enabled then return end
    if Config.Persistence.AutoSaveInterval <= 0 then return end
    if not State.IsOnCourse() then return end
    
    local now = os.time()
    if (now - lastSaveTime) >= Config.Persistence.AutoSaveInterval then
        Persistence.Save("autosave")
    end
end

-- ============== UTILS ==============

function Persistence.GetLoadedData()
    return loadedData
end

function Persistence.ForceSave()
    Persistence.Save("forced")
end

function Persistence.Init()
    lastSaveTime = os.time()
    loadedData = nil
    State.SetModuleStatus("persistence", true)
    return true
end

Persistence.Init()

return Persistence
