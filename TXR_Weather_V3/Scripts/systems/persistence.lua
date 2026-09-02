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
local PA_AUTOSAVE_S = 10   -- PA autosave cadence (s); on course it is Config.Persistence.AutoSaveInterval

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
    -- A NaN cloud/fog prints as "-nan(ind)", which tonumber rejects on the
    -- way back (the field would then load as a string, see readStateFile),
    -- so write the "unknown" sentinel instead
    if cloud ~= cloud then cloud = -1 end
    if fog ~= fog then fog = -1 end
    
    -- Never save invalid values, they corrupt the file for the next session
    -- (tod ~= tod rejects NaN, which passes both range checks and would be
    -- written as "nan", poisoning the file and its .bak on the next rotation)
    if tod ~= tod or tod < 0 or tod > 2400 then
        Log.Debug(MODULE, string.format("Skipping save (%s): invalid TOD: %.2f", reason or "auto", tod))
        -- Still update lastSaveTime to prevent spam retries
        lastSaveTime = os.time()
        return false
    end
    
    -- Write atomically (2026-07-30): io.open(path, "w") truncates at once, so
    -- a process kill between open and close (an Alt+F4 inside the 30 s
    -- autosave window) leaves an empty or torn last_state.txt, LoadRaw
    -- returns nil, nothing restores and UDS sits at its default Time Of Day
    -- (the midnight flash: "unrestored UDS reads Time Of Day = 0"). Write a
    -- temp file, keep the previous good file as .bak, then swap.
    local savePath = getSaveFilePath()
    local f = io.open(savePath .. ".tmp", "w")
    if f then
        local preset = State.GetCurrentPreset() or "Clear_Skies"
        local speed = State.GetTimeSpeed() or Config.TimeOfDay.DefaultSpeed
        if speed ~= speed then speed = Config.TimeOfDay.DefaultSpeed end

        f:write(string.format(
            "tod=%.6f,cloud=%.6f,fog=%.6f,preset=%s,speed=%.6f,paused=%d\n",
            tod,
            cloud,
            fog,
            preset,
            speed,
            State.IsTimePaused() and 1 or 0
        ))
        f:close()
        -- Swap the temp file into place; if the swap fails put the old file
        -- back, never leaving no state file at all. Rotate the backup only
        -- when a main file exists: in the degraded state (main lost to a
        -- crash, session restored from the .bak) an unconditional remove
        -- would destroy the last good copy before the new file is in place.
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
            -- Stamp the clock on failure too, or the 8 Hz tick re-runs the full
            -- save loop against a persistent lock instead of once per interval.
            lastSaveTime = os.time()
            Log.Warn(MODULE, "State save swap failed; previous file kept")
            return false
        end
        lastSaveTime = os.time()
        Log.Debug(MODULE, string.format("State saved (%s): TOD=%.2f cloud=%.2f fog=%.2f preset=%s",
            reason or "auto", tod, cloud, fog, preset))
        return true
    end
    -- Could not open the temp file (read-only folder, a sync or antivirus
    -- lock): stamp the clock like the other failure paths.
    lastSaveTime = os.time()
    Log.Warn(MODULE, "State save skipped: cannot open " .. savePath .. ".tmp")
    return false
end

-- ============== LOAD ==============

local NUMERIC_FIELDS = { tod = true, cloud = true, fog = true, speed = true, paused = true }

--- Read and parse one state file. Returns nil for missing, empty, truncated or
--- unparseable content, so the caller can fall back to the backup.
local function readStateFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end

    -- Parse key=value pairs. A numeric field that fails to parse (a NaN
    -- printed as "-nan(ind)", a hand edit) is dropped rather than kept as a
    -- string: Restore compares these with >=, and a string there raised out
    -- of main's course setup on every tick.
    local data = {}
    for k, v in line:gmatch("([%w_]+)=([^,]+)") do
        local n = tonumber(v)
        if n then
            data[k] = n
        elseif not NUMERIC_FIELDS[k] then
            data[k] = v
        end
    end
    -- tod is the field every caller keys on; without it the line is useless
    -- (a torn write usually leaves a valid prefix, so this is the real test)
    if type(data.tod) ~= "number" then return nil end
    return data
end

--- Load state from file and return raw data (no side effects)
--- @return table|nil data with tod, cloud, fog, preset, speed, paused
function Persistence.LoadRaw()
    local path = getSaveFilePath()
    local data = readStateFile(path)
    if data then return data end

    -- Main file missing, empty or truncated (a process kill mid-write): the
    -- .bak is the previous complete save, so at worst this costs one autosave
    -- interval of drift instead of dropping the restore and flashing midnight.
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
    
    -- Always read fresh from the file: across PA transitions the cached startup data is stale
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
                -- Only restore a speed matching a current config mode: a stale
                -- value (an older config's FastSpeed, a dusk slow-window
                -- capture) would run the clock at the wrong rate every session.
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
    -- back to the default: preset data may still exist, so Weather.Apply
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
    
    -- Old save files may still carry wetness=/puddle= fields from the removed
    -- wetness module; they parse harmlessly and go unread.

    return restored
end

-- ============== TICK ==============

function Persistence.Tick()
    if not Config.Persistence.Enabled then return end
    if Config.Persistence.AutoSaveInterval <= 0 then return end
    -- Course or PA (2026-08-08): the PA-exit save leg in LoadMapPreHook is
    -- dead in practice, the PA's actors go invalid seconds before the unload
    -- hook fires and IsInPAScene() is already false. In continue mode the PA
    -- clock runs, so autosaving here keeps the file within one interval of
    -- live PA time, which is what the course return restores. Safe against
    -- the canned-1950 trap: the first PA autosave is a full interval after
    -- the carry landed (main.lua applies PA state earlier in the same tick).
    local inPA = false
    pcall(function()
        local Actors = require("systems.actors")
        inPA = (Actors and Actors.IsInPAScene and Actors.IsInPAScene()) or false
    end)
    if not (State.IsOnCourse() or inPA) then return end
    
    -- The PA has no working exit save (its actors die before the unload
    -- hook), so this file is what the course return restores: the shorter
    -- PA interval caps the clock drift at PA_AUTOSAVE_S
    local now = os.time()
    local interval = inPA and PA_AUTOSAVE_S or Config.Persistence.AutoSaveInterval
    if (now - lastSaveTime) >= interval then
        Persistence.Save("autosave")
    end
end

-- ============== INIT ==============

function Persistence.Init()
    lastSaveTime = os.time()
    State.SetModuleStatus("persistence", true)
    return true
end

Persistence.Init()

return Persistence
