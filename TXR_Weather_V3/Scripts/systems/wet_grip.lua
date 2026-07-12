-- TXR Weather Mod v3.0
-- systems/wet_grip.lua
-- Dynamic wet grip: tire grip drops as the road gets wet (rain/snow) and recovers as it
-- dries. Reads live precipitation from Ultra Dynamic Weather and drives it into the
-- GLOBAL tire degradation table (DT_TireDegradationInfo). Because every car's tire model
-- reads that table, this:
--  , affects ALL cars, the player AND the AI rivals, and
--  , works in PA rival battles.
-- The global-tire-table grip approach is credited to Chrystales.
--
-- How it works: each update it reads UDW "Rain" (0-10), smooths it into a wetness value
-- (rises fast, dries slowly), then writes each tire row's grip RATES as the cached dry
-- value * a wet factor. We cache the dry originals once, so the scaling is always from
-- the bone-dry baseline and never compounds; at wetness 0 the originals are written back.
--
-- Only the grip rates are touched (longitudinal: Max/Cliff/MinGripRate; lateral:
-- Max/Cliff/MinSideGripRate). Tire life and braking are left alone; the degradation
-- table has no braking entry, so wet braking isn't part of this method.
--
-- Threading: precip read + smoothing run on the async loop thread; resolving the data
-- table and writing its rows are marshalled onto the game thread via ExecuteInGameThread.
--
-- NOTE (verify in-game): the data-table edit is global and definitely takes on cars as
-- they spawn (so AI/PA battles get it). Whether an ALREADY-spawned car (e.g. the player
-- when rain starts mid-drive) picks up a live edit is decided in the game's tire code; if
-- the player doesn't feel rain live until a respawn, we'd add back a player-only setter
-- pass to complement this. Config.WetGrip.Debug logs each re-apply.

local WetGrip = {}

local Log = require("core.logging")
local Config = require("config")
local Actors = require("systems.actors")

local MODULE = "WetGrip"

-- The global tire degradation data table that every car's tire model reads.
local DT_PATH = "/Game/ITSB/Core/Quest/DT_TireDegradationInfo.DT_TireDegradationInfo"

-- Grip-rate fields scaled by the wet factor (degradation curve endpoints).
local MAIN_FIELDS = { "MaxGripRate", "CliffGripRate", "MinGripRate" }       -- longitudinal
local SIDE_FIELDS = { "MaxSideGripRate", "CliffSideGripRate", "MinSideGripRate" } -- lateral

local cfg = nil
local initialized = false
local enabled = false

-- Smoothing + apply state (module-scope, persists for the whole game session).
local wet_current = 0.0   -- smoothed wetness, 0 (bone dry) .. 1 (as slick as it gets)
local lastUpdate  = 0.0   -- os.clock of the last recompute (throttle)
local _dbgLast    = 0.0   -- os.clock of the last debug line
local lastMainF   = nil   -- last main/side factors written to the table (nil = not yet)
local lastSideF   = nil
local origRows    = nil   -- cached DRY originals: origRows[rowName][field] = value
local dtHandle    = nil   -- cached data-table object

-- ============== helpers ==============

local function valid(o) return o and o.IsValid and o:IsValid() end

local function get_udw()
    local udw = Actors.GetUDW()
    if valid(udw) then return udw end
    pcall(function() udw = FindFirstOf("Ultra_Dynamic_Weather_C") end)
    if valid(udw) then return udw end
    return nil
end

-- Current precipitation as a 0-10 intensity (UDW "Rain", plus "Snow" if SnowCounts).
-- Returns nil if no weather actor exists (wetness then just holds / decays toward dry).
local function read_precip_0_10()
    local udw = get_udw()
    if not udw then return nil end
    local function rd(name)
        local v = nil
        local ok = pcall(function() v = udw[name] end)
        if ok and type(v) == "number" then return v end
        return nil
    end
    local precip = rd("Rain") or 0.0
    if cfg.SnowCounts then
        local snow = rd("Snow") or 0.0
        precip = math.max(precip, snow * (cfg.SnowWeight or 1.0))
    end
    return precip
end

local function get_dt()
    if valid(dtHandle) then return dtHandle end
    local dt = nil
    pcall(function() dt = StaticFindObject(DT_PATH) end)
    if valid(dt) then dtHandle = dt; return dt end
    return nil
end

-- Scale the table's grip rates to (dry original * factor). On the first successful pass
-- the dry originals are captured (once, for the session) so scaling never compounds.
-- Must run on the game thread. Returns true if the table was found and written.
local function apply_wet_to_dt(mainF, sideF)
    local dt = get_dt()
    if not dt then return false end

    local building = (origRows == nil)
    local cache = building and {} or origRows

    local ok = pcall(function()
        dt:ForEachRow(function(rowName, rowData)
            local name = tostring(rowName)

            -- Capture dry originals the first time we ever see this row.
            local orig = cache[name]
            if building then
                orig = {}
                for _, f in ipairs(MAIN_FIELDS) do
                    local v = nil; pcall(function() v = rowData[f] end)
                    if type(v) == "number" then orig[f] = v end
                end
                for _, f in ipairs(SIDE_FIELDS) do
                    local v = nil; pcall(function() v = rowData[f] end)
                    if type(v) == "number" then orig[f] = v end
                end
                cache[name] = orig
            end

            if orig then
                for _, f in ipairs(MAIN_FIELDS) do
                    if orig[f] then pcall(function() rowData[f] = orig[f] * mainF end) end
                end
                for _, f in ipairs(SIDE_FIELDS) do
                    if orig[f] then pcall(function() rowData[f] = orig[f] * sideF end) end
                end
            end
        end)
    end)

    if not ok then return false end
    if building then origRows = cache end
    return true
end

-- ============== PUBLIC API ==============

function WetGrip.Init()
    if initialized then return true end
    cfg = Config.WetGrip or {}
    enabled = (cfg.Enabled == true)
    initialized = true
    Log.Info(MODULE, "Initializing dynamic wet grip (global tire table)", {
        enabled = enabled,
        gripFloor = cfg.MinGripMult,
        sideFloor = cfg.MinSideGripMult,
        fullWetAt = cfg.PrecipForFullWet,
    })
    return true
end

-- Force a re-apply on course entry (incl. returning from PA) in case a level load reset
-- the table back to its cooked dry values. Does NOT touch the cached dry originals.
function WetGrip.OnCourseLoad()
    lastMainF, lastSideF = nil, nil
    Log.Debug(MODULE, "Wet grip will re-assert table on course load")
end

-- Driven from the main loop (8 Hz); self-throttled to UpdateMs. Re-applies the table only
-- when the wet factor actually changes, so it's a cheap no-op most ticks.
function WetGrip.Tick()
    if not initialized or not enabled then return end

    local now = os.clock()
    local interval = (cfg.UpdateMs or 250) / 1000.0
    if (now - lastUpdate) < interval then return end
    lastUpdate = now
    -- Smooth with the FIXED update period (not real elapsed) so the rise/dry-seconds
    -- tuning stays calibrated and a long gap can't snap wetness in one jump.
    local dt = interval

    -- Target wetness from precipitation, smoothed (rise fast, dry slowly).
    local precip = read_precip_0_10()
    if precip ~= nil then
        local denom  = cfg.PrecipForFullWet or 7.0
        local target = (denom > 0) and (precip / denom) or 0.0
        if target < 0 then target = 0 elseif target > 1 then target = 1 end
        local tau = (target > wet_current) and (cfg.WetRiseSeconds or 8.0)
                                            or (cfg.DrySeconds or 45.0)
        local a = (tau > 0) and (1.0 - math.exp(-dt / tau)) or 1.0
        wet_current = wet_current + (target - wet_current) * a
        if wet_current < 0 then wet_current = 0 elseif wet_current > 1 then wet_current = 1 end
    end

    local mainF = 1.0 + (cfg.MinGripMult     - 1.0) * wet_current
    local sideF = 1.0 + (cfg.MinSideGripMult - 1.0) * wet_current

    -- Only re-write the table when the factor meaningfully changed (or after a course
    -- load forced a re-assert). The table holds its values otherwise.
    local changed = (lastMainF == nil)
        or (math.abs(mainF - lastMainF) > 1e-4)
        or (math.abs(sideF - lastSideF) > 1e-4)

    if cfg.Debug and (now - _dbgLast) >= 2.0 then
        _dbgLast = now
        Log.Info(MODULE, string.format("DBG precip=%s wetness=%.2f mainF=%.3f sideF=%.3f changed=%s cached=%s",
            tostring(precip), wet_current, mainF, sideF, tostring(changed), tostring(origRows ~= nil)))
    end

    if not changed then return end

    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(function()
            if apply_wet_to_dt(mainF, sideF) then
                lastMainF, lastSideF = mainF, sideF
                if cfg.Debug then
                    Log.Info(MODULE, string.format("DBG applied table grip x%.3f side x%.3f (wetness %.2f)",
                        mainF, sideF, wet_current))
                end
            elseif cfg.Debug then
                Log.Info(MODULE, "DBG table not found yet: will retry")
            end
        end)
    end
end

function WetGrip.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        wetness = wet_current,
        mainFactor = lastMainF,
        sideFactor = lastSideF,
        tableCached = origRows ~= nil,
    }
end

return WetGrip
