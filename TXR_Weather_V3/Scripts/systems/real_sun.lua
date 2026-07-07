-- TXR Weather Mod v3.0
-- systems/real_sun.lua
-- Real-world solar simulation experiment.
-- Phase 0 (always on): probe - logs the sky's stock Simulation-category values
-- once per course (grep "RealSun"), so we know what TXR ships before writing.
-- Phase 1 (Config.RealSun.Enabled): switch UDS to Simulate Real Sun/Moon with
-- Tokyo coordinates and a pinned date - astronomically correct sunrise/sunset
-- times and sun path for that date. Settle-gated one-shot per course on the
-- game thread (the proven recipe). The sky actor is recreated every course, so
-- disabling the experiment needs no revert.
--
-- Property names verified against the v1.5 dump (shared/types/Ultra_Dynamic_Sky.lua).
-- Deliberately does NOT touch "Simulate Real Stars" - the Stars module owns it.

local RealSun = {}

local Log = require("core.logging")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "RealSun"

-- ============== UDS PROPERTY NAMES (verified, v1.5 dump) ==============
local PROP_SIM_SUN    = "Simulate Real Sun"
local PROP_SIM_MOON   = "Simulate Real Moon"
local PROP_SIM_STARS  = "Simulate Real Stars"   -- probe only
local PROP_LATITUDE   = "Latitude"
local PROP_LONGITUDE  = "Longitude"
local PROP_TIME_ZONE  = "Time Zone"
local PROP_YEAR       = "Year"
local PROP_MONTH      = "Month"
local PROP_DAY        = "Day"
local PROP_NORTH_YAW  = "North Yaw"
local PROP_SYS_TIME   = "Use System Time"       -- probe only
local PROP_APPLY_DST  = "Apply Daylight Savings Time"

-- Bakers (same family as the proven Stars fix: flip the bool, then have UDS
-- re-read its static setup). Sun position itself updates dynamically, but the
-- Simulate flags may be sampled during static setup like Real Stars was.
local STATIC_FNS = {
    "Static Properties - Sun",
    "Static Properties - Moon",
}

local SETTLE_TICKS = 32  -- ~4s at 8 Hz past BeginPlay (proven settle gate)

-- ============== STATE ==============
local initialized = false
local enabled = false
local cfg = nil
local settleTicks = 0
local doneThisCourse = false
local lastProbe = nil

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local function getUDS()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDS()
end

-- ============== GAME-THREAD WORK ==============

local function readProp(uds, prop)
    local v = nil
    pcall(function() v = uds[prop] end)
    return v
end

--- Write an absolute value; records "old->new" in the changes table.
local function setAbs(uds, prop, value, changes)
    if value == nil then return end
    local old = readProp(uds, prop)
    local ok = pcall(function() uds[prop] = value end)
    if ok then
        changes[prop] = string.format("%s->%s", tostring(old), tostring(value))
    else
        Log.Warn(MODULE, "Write failed", {prop = prop})
    end
end

local function runOnGameThread()
    local uds = getUDS()
    if not uds then return end

    -- Phase 0: probe the stock values (runs whether or not the experiment is on)
    local probe = {
        sim_sun    = tostring(readProp(uds, PROP_SIM_SUN)),
        sim_moon   = tostring(readProp(uds, PROP_SIM_MOON)),
        sim_stars  = tostring(readProp(uds, PROP_SIM_STARS)),
        latitude   = tostring(readProp(uds, PROP_LATITUDE)),
        longitude  = tostring(readProp(uds, PROP_LONGITUDE)),
        time_zone  = tostring(readProp(uds, PROP_TIME_ZONE)),
        year       = tostring(readProp(uds, PROP_YEAR)),
        month      = tostring(readProp(uds, PROP_MONTH)),
        day        = tostring(readProp(uds, PROP_DAY)),
        north_yaw  = tostring(readProp(uds, PROP_NORTH_YAW)),
        sys_time   = tostring(readProp(uds, PROP_SYS_TIME)),
        apply_dst  = tostring(readProp(uds, PROP_APPLY_DST)),
    }
    lastProbe = probe
    Log.Info(MODULE, "Sim probe (stock)", probe)

    -- Exposure-surface probe: UDS's native exposure system (the engine.ini
    -- MethodOverride=3 cvar likely overrides it, and UDS's own PostProcess
    -- component is not composited by TXR - these stock values + a later bias
    -- liveness test decide whether any of it is usable as Layer 2).
    local expProbe = {
        apply_exposure = tostring(readProp(uds, "Apply Exposure Settings")),
        metering_mode  = tostring(readProp(uds, "Exposure Metering Mode")),
        bias_day       = tostring(readProp(uds, "Exposure Bias Day")),
        bias_night     = tostring(readProp(uds, "Exposure Bias Night")),
        bias_cloudy    = tostring(readProp(uds, "Exposure Bias Cloudy")),
        bias_foggy     = tostring(readProp(uds, "Exposure Bias Foggy")),
        bias_dusty     = tostring(readProp(uds, "Exposure Bias Dusty")),
        interior_adjust = tostring(readProp(uds, "Apply Interior Adjustments")),
        bias_interior  = tostring(readProp(uds, "Exposure Bias In Interior")),
        sky_mult_interior  = tostring(readProp(uds, "Sky Light Intensity Multiplier In Interiors")),
        sun_mult_interior  = tostring(readProp(uds, "Sun Light Intensity Multiplier In Interiors")),
        moon_mult_interior = tostring(readProp(uds, "Moon Light Intensity Multiplier In Interiors")),
    }
    pcall(function()
        local r = uds["Exposure Brightness Range"]
        if r then
            local lo, hi = nil, nil
            pcall(function() lo = r.LowerBound.Value end)
            pcall(function() hi = r.UpperBound.Value end)
            expProbe.brightness_range = tostring(lo) .. ".." .. tostring(hi)
        end
    end)
    pcall(function()
        local fn = uds["Current Exposure Bias"]
        if fn then expProbe.current_bias = tostring(fn(uds)) end
    end)
    Log.Info(MODULE, "Exposure probe (stock)", expProbe)

    -- Source-light probe: the Layer 1 lever surface (available light). These
    -- stock values are the baselines the light-cycle rework scales from.
    local lightProbe = {
        sun_intensity   = tostring(readProp(uds, "Sun Light Intensity")),
        moon_intensity  = tostring(readProp(uds, "Moon Light Intensity")),
        sky_light       = tostring(readProp(uds, "Sky Light Intensity")),
        night_brightness = tostring(readProp(uds, "Night Brightness")),
        night_bright_cloudy = tostring(readProp(uds, "Extra Night Brightness When Cloudy")),
        absent_brightness = tostring(readProp(uds, "Directional Lights Absent Brightness")),
        night_sky_glow  = tostring(readProp(uds, "Night Sky Glow")),
        light_pollution = tostring(readProp(uds, "Light Pollution Intensity")),
        overcast_day    = tostring(readProp(uds, "Overcast Brightness Day")),
        overcast_night  = tostring(readProp(uds, "Overcast Brightness Night")),
    }
    Log.Info(MODULE, "Light probe (stock)", lightProbe)

    -- Date pin (user policy 2026-07-07: pinnable, default off = seasons drift).
    -- The game itself persists the drifting date across sessions, so unpinned
    -- play is already continuous; the pin forces one fixed sun path per course.
    if cfg.PinMonth and cfg.PinDay then
        local changes = {}
        setAbs(uds, PROP_YEAR, cfg.PinYear, changes)
        setAbs(uds, PROP_MONTH, cfg.PinMonth, changes)
        setAbs(uds, PROP_DAY, cfg.PinDay, changes)
        Log.Info(MODULE, "Date pinned", changes)
    end

    -- Interior-system probe (TEMPORARY): stock ships Apply Interior
    -- Adjustments=false - the occlusion cache may read 0.000 in tunnels simply
    -- because the system never runs. Stock interior multipliers are all 1.0
    -- and the interior bias is 0, so enabling it is visually a NO-OP even if
    -- alive - a pure probe. Verdict comes from light_cycle's "Interior
    -- occlusion" watcher while driving a tunnel with this on.
    if cfg.EnableInteriorProbe then
        local changes = {}
        setAbs(uds, "Apply Interior Adjustments", true, changes)
        Log.Info(MODULE, "Interior probe enabled", changes)
    end

    if not enabled then return end

    -- Phase 1: switch to the real-world simulation
    local changes = {}
    setAbs(uds, PROP_LATITUDE, cfg.Latitude, changes)
    setAbs(uds, PROP_LONGITUDE, cfg.Longitude, changes)
    setAbs(uds, PROP_TIME_ZONE, cfg.TimeZone, changes)
    setAbs(uds, PROP_YEAR, cfg.Year, changes)
    setAbs(uds, PROP_MONTH, cfg.Month, changes)
    setAbs(uds, PROP_DAY, cfg.Day, changes)
    setAbs(uds, PROP_NORTH_YAW, cfg.NorthYaw, changes)
    setAbs(uds, PROP_APPLY_DST, false, changes)
    setAbs(uds, PROP_SIM_SUN, true, changes)
    if cfg.RealMoon ~= false then
        setAbs(uds, PROP_SIM_MOON, true, changes)
    end

    -- Bake: have UDS re-read its sun/moon static setup
    for _, fnName in ipairs(STATIC_FNS) do
        local fn = nil
        pcall(function() fn = uds[fnName] end)
        if fn then
            local ok, err = pcall(function() fn(uds) end)
            if not ok then
                Log.Warn(MODULE, "Static apply failed", {fn = fnName, error = tostring(err)})
            end
        else
            Log.Warn(MODULE, "Static apply function not found", {fn = fnName})
        end
    end

    Log.Info(MODULE, "Real sun applied", changes)
end

local function run()
    if not getUDS() then return end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(runOnGameThread) end)
    else
        runOnGameThread()
    end
end

-- ============== PUBLIC API ==============

function RealSun.Init()
    if initialized then return true end
    cfg = Config.RealSun or {}
    enabled = cfg.Enabled == true
    initialized = true
    Log.Info(MODULE, "Initializing real sun module", {enabled = enabled})
    return true
end

--- Per-tick: probe (+apply when enabled) once per course, after the settle gate.
function RealSun.Tick()
    if not initialized then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        doneThisCourse = false
        return
    end

    settleTicks = settleTicks + 1
    if not doneThisCourse and settleTicks >= SETTLE_TICKS then
        doneThisCourse = true
        run()
    end
end

function RealSun.GetStatus()
    return {
        initialized = initialized,
        enabled = enabled,
        doneThisCourse = doneThisCourse,
        lastProbe = lastProbe,
    }
end

return RealSun
