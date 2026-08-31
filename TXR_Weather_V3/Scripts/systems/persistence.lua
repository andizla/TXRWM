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
    local name = (Config.Persistence and Config.Persistence.SaveFileName) or "last_state.txt"
    return getModRoot() .. "\\" .. name
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
    
    -- CRITICAL: Don't save invalid values; they corrupt the file for next session
    -- (tod ~= tod rejects NaN, which passes both range checks and would be
    -- written as "nan", poisoning the file AND its .bak on the next rotation)
    if tod ~= tod or tod < 0 or tod > 2400 then
        Log.Debug(MODULE, string.format("Skipping save (%s): invalid TOD: %.2f", reason or "auto", tod))
        -- Still update lastSaveTime to prevent spam retries
        lastSaveTime = os.time()
        return false
    end
    
    -- Write ATOMICALLY (2026-07-30). io.open(path, "w") TRUNCATES the file
    -- immediately, so killing the process between the open and the close leaves
    -- an empty or half-written last_state.txt. The autosave fires every 30 s
    -- while on course, so an Alt+F4 has a real chance of landing inside that
    -- window. LoadRaw then returns nil, nothing restores, and UDS sits at its
    -- DEFAULT Time Of Day: that is the midnight flash main.lua's disarm comment
    -- describes ("unrestored UDS reads Time Of Day = 0"). Write to a temp file,
    -- keep the previous good file as .bak, then swap the two.
    local savePath = getSaveFilePath()
    local f = io.open(savePath .. ".tmp", "w")
    if f then
        local preset = State.GetCurrentPreset() or "Clear_Skies"

        f:write(string.format(
            "tod=%.6f,cloud=%.6f,fog=%.6f,preset=%s,speed=%.6f,paused=%d\n",
            tod,
            cloud,
            fog,
            preset,
            State.GetTimeSpeed() or Config.TimeOfDay.DefaultSpeed,
            State.IsTimePaused() and 1 or 0
        ))
        f:close()
        -- Swap the temp file into place, keeping the previous good file as
        -- .bak. If the swap fails, put the old file back: never end up with no
        -- state file at all, which is the very failure this is fixing.
        -- Rotate the backup ONLY when a main file exists: in the degraded
        -- state (main lost to a crash, session restored FROM the .bak) an
        -- unconditional remove would destroy the last good copy before the
        -- new file is in place.
        local bak = savePath .. ".bak"
        local movedOld = nil
        local mainFile = io.open(savePath, "r")
        if mainFile then
            mainFile:close()
            os.remove(bak)
            movedOld = os.rename(savePath, bak)
        end
        if not os.rename(savePath .. ".tmp", savePath) then
            if movedOld then os.rename(bak, savePath) end
            os.remove(savePath .. ".tmp")
            -- Also stamp the clock on failure (mirrors the invalid-TOD skip
            -- above): without it the 8 Hz tick re-runs the FULL save loop
            -- against a persistent lock instead of once per interval.
            lastSaveTime = os.time()
            Log.Warn(MODULE, "State save swap failed; previous file kept")
            return false
        end
        lastSaveTime = os.time()
        Log.Debug(MODULE, string.format("State saved (%s): TOD=%.2f cloud=%.2f fog=%.2f preset=%s",
            reason or "auto", tod, cloud, fog, preset))
        return true
    end
    return false
end

-- ============== LOAD ==============

--- Load state from file and return raw data (no side effects)
--- @return table|nil data with tod, cloud, fog, preset, speed, paused
--- Read and parse one state file. Returns nil for missing, empty, truncated or
--- unparseable content, so the caller can fall back to the backup.
local function readStateFile(path)
    local f = io.open(path, "r")
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
    -- tod is the field every caller keys on; without it the line is useless
    -- (a torn write usually leaves a valid PREFIX, so this is the real test)
    if type(data.tod) ~= "number" then return nil end
    return data
end

function Persistence.LoadRaw()
    local path = getSaveFilePath()
    local data = readStateFile(path)
    if data then return data end

    -- Main file missing, empty or truncated: a process kill mid-write (Alt+F4
    -- during testing, or a real crash) lands here. The .bak is the previous
    -- complete save, so at worst this costs one autosave interval of drift
    -- instead of dropping the restore entirely and flashing midnight.
    local fallback = readStateFile(path .. ".bak")
    if fallback then
        Log.Warn(MODULE, "State file unreadable; restored from backup")
        return fallback
    end
    return nil
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
                -- Only restore a speed that matches a CURRENT config mode.
                -- The file can hold a stale value (an older config's FastSpeed,
                -- or a dusk slow-window capture) which would silently run the
                -- clock at the wrong rate every session until resaved.
                local speed = data.speed
                local def = Config.TimeOfDay.DefaultSpeed
                local fast = Config.TimeOfDay.FastSpeed
                if math.abs(speed - def) >= 1
                   and not (fast and math.abs(speed - fast) < 1) then
                    Log.Info(MODULE, "Persisted speed stale: using default",
                        {saved = speed, default = def})
                    speed = def
                end
                TimeOfDay.SetSpeed(speed)
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
    
    -- Restore preset. A persisted preset that is no longer in the active
    -- cycle (e.g. a rain variant saved before the no-rain build) falls
    -- back to the default: preset DATA may still exist, so Weather.Apply
    -- would happily re-summon a disabled weather.
    if data.preset then
        local applyPreset = data.preset
        local cycle = Config.Weather and Config.Weather.PresetCycleOrder
        if type(cycle) == "table" and #cycle > 0 then
            local inCycle = false
            for _, name in ipairs(cycle) do
                if name == applyPreset then inCycle = true break end
            end
            if not inCycle then
                local fallback = (Config.Weather and Config.Weather.DefaultPreset)
                    or "Clear_Skies"
                Log.Info(MODULE, "Persisted preset is disabled: falling back", {
                    persisted = applyPreset, fallback = fallback,
                })
                applyPreset = fallback
            end
        end
        local Weather = nil
        pcall(function() Weather = require("systems.weather") end)
        if Weather and Weather.Apply then
            Weather.Apply(applyPreset, 1.0)
            restored = true
        end
    end
    
    -- (Wetness restore removed with the module; old save files may still
    -- carry wetness=/puddle= fields, which parse harmlessly and go unread.)

    return restored
end

-- ============== TICK ==============

function Persistence.Tick()
    if not Config.Persistence.Enabled then return end
    if Config.Persistence.AutoSaveInterval <= 0 then return end
    -- Course OR PA (2026-08-08): the PA-exit save leg in LoadMapPreHook is
    -- dead in practice - the PA's actors go invalid seconds BEFORE the
    -- unload hook fires, so IsInPAScene() is already false by then and the
    -- exit time never reaches the file. In continue mode the PA clock runs;
    -- autosaving here keeps the file within one interval of live PA time,
    -- which is what the course return actually restores. Safe against the
    -- canned-1950 trap: the first PA autosave is a full interval after the
    -- carry landed (main.lua applies PA state earlier in the same tick).
    local inPA = false
    pcall(function()
        local Actors = require("systems.actors")
        inPA = (Actors and Actors.IsInPAScene and Actors.IsInPAScene()) or false
    end)
    if not (State.IsOnCourse() or inPA) then return end
    
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
