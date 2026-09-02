-- TXR Weather Mod v3.0
-- systems/scheduler.lua
-- Phase 11: Random weather preset scheduler.
--
-- Drives weather changes on a randomized interval from a weighted preset pool.
-- All changes route through Weather.Apply() so the rain/dry/clouds/fog/
-- lightning/audio pipeline stays in the loop; UDW's native Random Weather
-- Variation would bypass it and fight the manual-override suppression.
-- If the current preset changes to something the scheduler did not set
-- (Alt+S cycle, Alt+R reset, a persistence restore) the timer re-arms so a
-- deliberate pick is never instantly stomped.

local Scheduler = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local Config = require("config")
local Presets = require("systems.presets")

-- Lazy-load to avoid circular dependencies (weather/actors require chains)
local Weather = nil
local Actors = nil
local TimeOfDay = nil

local MODULE = "Scheduler"

-- ============== STATE ==============
local nextChangeAt = 0       -- os.time() seconds at which the next auto change is due
local heldUntil = 0          -- HoldFor deadline; external-change re-arms never land before it
local lastSetPreset = nil    -- the preset the scheduler last applied (for external-change detection)
local wasOnCourse = false    -- edge-detect course entry so we arm the timer once
local changeCount = 0        -- diagnostics
local seeded = false

-- ============== INTERNAL ==============

local function getWeather()
    if not Weather then
        local ok, mod = pcall(require, "systems.weather")
        if ok then Weather = mod end
    end
    return Weather
end

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getTimeOfDay()
    if not TimeOfDay then
        local ok, mod = pcall(require, "systems.time_of_day")
        if ok then TimeOfDay = mod end
    end
    return TimeOfDay
end

--- Current time-of-day period ("day"/"night"/"dawn"/"dusk") or nil if unknown.
local function currentPeriod()
    local tod = getTimeOfDay()
    if tod and tod.GetPeriod then
        local ok, p = pcall(tod.GetPeriod)
        if ok and p and p ~= "unknown" then return p end
    end
    return nil
end

--- Effective weight for a preset: base weight x time-of-day multiplier, with the
--- precipitation filter applied. Returns 0 if the preset should not be picked.
--- @param name string
--- @param baseW number|nil
--- @param period string|nil
--- @param allowPrecip boolean
--- @return number
local function effectiveWeight(name, baseW, period, allowPrecip)
    if not baseW or baseW <= 0 then return 0 end
    if not Presets.Exists(name) then return 0 end
    if not allowPrecip and not Presets.IsDry(name) then return 0 end

    local mult = 1.0
    local tw = Config.Scheduler and Config.Scheduler.TimeWeights
    if period and tw and tw[period] and tw[period][name] ~= nil then
        mult = tw[period][name]
    end
    return baseW * mult
end

--- Schedule the next auto change at now + a random interval within the configured range.
local function armTimer()
    local cfg = Config.Scheduler or {}
    local minS = cfg.MinIntervalSeconds or 180
    local maxS = cfg.MaxIntervalSeconds or 480
    if maxS < minS then maxS = minS end
    local interval = minS + math.random() * (maxS - minS)
    nextChangeAt = os.time() + interval
    Log.Debug(MODULE, "Timer armed", { inSeconds = math.floor(interval) })
end

--- Weighted random pick from the configured pool, factoring in the current
--- time-of-day multipliers and the precipitation filter.
--- @param exclude string|nil A preset to skip (used to avoid repeating the current one)
--- @return string|nil A valid preset name, or nil if the pool is empty
local function weightedPick(exclude)
    local cfg = Config.Scheduler or {}
    local weights = cfg.Weights or {}
    local allowPrecip = cfg.AllowPrecipitation ~= false  -- default true
    local period = currentPeriod()

    local function sumWeights(excludeName)
        local total = 0
        for name, w in pairs(weights) do
            if name ~= excludeName then
                total = total + effectiveWeight(name, w, period, allowPrecip)
            end
        end
        return total
    end

    local total = sumWeights(exclude)

    -- If excluding the current preset emptied the pool, retry without exclusion.
    if total <= 0 then
        exclude = nil
        total = sumWeights(nil)
        if total <= 0 then
            Log.Warn(MODULE, "No valid presets in weight pool", {
                period = period or "unknown", allowPrecip = allowPrecip,
            })
            return nil
        end
    end

    local r = math.random() * total
    local acc = 0
    local last = nil
    for name, w in pairs(weights) do
        if name ~= exclude then
            local ew = effectiveWeight(name, w, period, allowPrecip)
            if ew > 0 then
                last = name
                acc = acc + ew
                if r <= acc then
                    return name
                end
            end
        end
    end
    -- Floating-point fallthrough: return the last candidate seen.
    return last
end

-- ============== PUBLIC API ==============

--- Initialize the scheduler.
function Scheduler.Init()
    if not seeded then
        math.randomseed(os.time())
        -- A couple of warm-up draws (some Lua builds bias the first call).
        math.random(); math.random()
        seeded = true
    end
    local cfg = Config.Scheduler or {}
    Log.Info(MODULE, "Initializing scheduler", {
        enabled = cfg.Enabled == true,
        minInterval = cfg.MinIntervalSeconds,
        maxInterval = cfg.MaxIntervalSeconds,
    })
    return true
end

--- Pick a weighted-random preset (excluding the current one) and apply it.
--- Re-arms the timer regardless of auto-mode, so it works as the Alt+P handler too.
--- @return string|nil The applied preset name, or nil if nothing was applied
function Scheduler.PickAndApply()
    local weather = getWeather()
    if not weather then
        Log.Warn(MODULE, "Weather module not available")
        return nil
    end
    if Config.Weather and Config.Weather.Enabled == false then
        Log.Debug(MODULE, "Weather master switch off: skipping pick")
        return nil
    end

    local current = weather.GetCurrent()
    local pick = weightedPick(current)
    if not pick then return nil end

    local transition = (Config.Scheduler and Config.Scheduler.TransitionSeconds) or 15.0
    local ok = weather.Apply(pick, transition)
    armTimer()  -- arm even on failure so we retry after a full interval, not every tick
    if ok then
        lastSetPreset = pick
        changeCount = changeCount + 1
        Log.Info(MODULE, "Scheduled weather change", {
            from = current or "none", to = pick, period = currentPeriod() or "unknown",
        })
        return pick
    end
    Log.Debug(MODULE, "Weather.Apply rejected pick (not on course / disabled)", { pick = pick })
    return nil
end

--- Alt+P handler: force a random change now, independent of auto-mode.
function Scheduler.PickNow()
    return Scheduler.PickAndApply()
end

--- Hold automatic changes for the given seconds (2026-07-28, test-rain
--- support: a forced experiment preset must not be scheduler-swapped
--- mid-test; the 01:21 log had Rain -> Overcast land mid-occlusion-run).
--- Also adopts the current preset so external-change detection does not
--- shorten the hold.
function Scheduler.HoldFor(seconds)
    -- max(): a hold must never pull in a change already further out
    -- (photomode's 30 s close-hold vs a pick still minutes away). heldUntil
    -- makes the hold stick: the external-change branch in Tick re-arms a
    -- normal interval when the hold's own apply lands after the HoldFor call
    -- (leak test: HoldFor then ApplyFast) and clamps back up to this.
    heldUntil = os.time() + (tonumber(seconds) or 300)
    if heldUntil > nextChangeAt then nextChangeAt = heldUntil end
    pcall(function()
        local weather = getWeather()
        if weather and weather.GetCurrent then
            lastSetPreset = weather.GetCurrent()
        end
    end)
    Log.Info(MODULE, "Auto changes held", {seconds = tonumber(seconds) or 300})
end

--- Drop an active hold and arm a fresh interval. HoldFor can only push the
--- next change further out (its max() keeps a longer hold intact), so a
--- one-second HoldFor never released the leak test's two-hour hold.
function Scheduler.Release()
    heldUntil = 0
    armTimer()
    pcall(function()
        local weather = getWeather()
        if weather and weather.GetCurrent then
            lastSetPreset = weather.GetCurrent()
        end
    end)
    Log.Info(MODULE, "Auto changes released")
end

--- Per-tick update. Gated in main.lua by PA-freeze; we add the on-course /
--- master-switch / external-change handling here.
function Scheduler.Tick()
    local cfg = Config.Scheduler or {}
    if cfg.Enabled ~= true then return end

    local weather = getWeather()
    if not weather then return end
    if Config.Weather and Config.Weather.Enabled == false then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        wasOnCourse = false
        return
    end

    -- Course just (re)entered: arm a fresh timer and adopt whatever preset is
    -- active (persistence restore / default), so the first auto change is a full
    -- interval away rather than immediate.
    if not wasOnCourse then
        wasOnCourse = true
        lastSetPreset = weather.GetCurrent()
        armTimer()
        -- A course (re)entry must not truncate an explicit HoldFor either
        -- (the external-change branch below already clamps).
        if nextChangeAt < heldUntil then nextChangeAt = heldUntil end
        return
    end

    -- External change detection: if the preset is no longer what we last set,
    -- someone changed it manually (Alt+S/Alt+R) or it was restored. Adopt it and
    -- push the next auto change out so a manual pick is not immediately lost.
    local current = weather.GetCurrent()
    if current ~= lastSetPreset then
        lastSetPreset = current
        armTimer()
        if nextChangeAt < heldUntil then nextChangeAt = heldUntil end
        return
    end

    -- Don't stack a new change on top of an in-progress transition.
    if weather.IsTransitioning and weather.IsTransitioning() then
        return
    end

    if os.time() >= nextChangeAt then
        Scheduler.PickAndApply()
    end
end

return Scheduler
