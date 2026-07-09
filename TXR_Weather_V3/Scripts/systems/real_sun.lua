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
    -- UDS's own computed sun events for the current date (data for aligning
    -- fallback windows and for the seasons feature; the elevation driver does
    -- not need them).
    pcall(function()
        local fn = uds["Current Sunrise Event Time"]
        if fn then probe.sunrise_event = tostring(fn(uds)) end
    end)
    pcall(function()
        local fn = uds["Current Sunset Event Time"]
        if fn then probe.sunset_event = tostring(fn(uds)) end
    end)

    lastProbe = probe
    Log.Debug(MODULE, "Sim probe (stock)", probe)

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
    Log.Debug(MODULE, "Exposure probe (stock)", expProbe)

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
        skylight_mode   = tostring(readProp(uds, "Sky Light Mode")),
        realtime_capture = tostring(readProp(uds, "Real Time Capture")),
    }
    Log.Debug(MODULE, "Light probe (stock)", lightProbe)

    -- Game PP-component probe: the course sky / course weather / HDR actors
    -- carry their own composited PostProcess components - the devs' exposure
    -- plumbing (Curve_ExposureCompensation lives in the same folder). Reads
    -- each component's exposure-relevant settings once per course.
    for _, cls in ipairs({"BP_CourseSky_C", "BP_CourseWeather_C", "BP_HDR_C"}) do
        pcall(function()
            local a = FindFirstOf(cls)
            if not (a and a.IsValid and a:IsValid()) then return end
            local pp = nil
            pcall(function() pp = a.PostProcess end)
            if not (pp and pp.IsValid and pp:IsValid()) then
                Log.Debug(MODULE, "Game PP probe: " .. cls .. " has no PostProcess")
                return
            end
            local info = {}
            pcall(function() info.enabled = tostring(pp.bEnabled) end)
            pcall(function() info.unbound = tostring(pp.bUnbound) end)
            pcall(function() info.weight = tostring(pp.BlendWeight) end)
            pcall(function()
                local s = pp.Settings
                info.ov_bias   = tostring(s.bOverride_AutoExposureBias)
                info.bias      = tostring(s.AutoExposureBias)
                info.ov_curve  = tostring(s.bOverride_AutoExposureBiasCurve)
                pcall(function()
                    local c = s.AutoExposureBiasCurve
                    if c then info.curve = c:GetFullName():match("([^%.%s]+)$") or "set" end
                end)
                info.ov_minb   = tostring(s.bOverride_AutoExposureMinBrightness)
                info.minb      = tostring(s.AutoExposureMinBrightness)
                info.ov_maxb   = tostring(s.bOverride_AutoExposureMaxBrightness)
                info.maxb      = tostring(s.AutoExposureMaxBrightness)
                info.ov_method = tostring(s.bOverride_AutoExposureMethod)
            end)
            Log.Debug(MODULE, "Game PP probe: " .. cls, info)
        end)
    end

    -- TXR post-process volume IDENTIFICATION (2026-07-08 v2): all volumes,
    -- with world position + bounds (for mapping onto known tunnel locations
    -- and for a future camera-containment signal: tunnel rain kill + tunnel
    -- exposure trim) and a WIDE override sweep (reports which settings each
    -- volume actually overrides - the authored purpose).
    pcall(function()
        local vols = FindAllOf("PostProcessVolume")
        if not vols or #vols == 0 then
            Log.Debug(MODULE, "PP volume probe: none found")
            return
        end
        Log.Debug(MODULE, "PP volume probe", {count = #vols})
        local FLAGS = {
            "AutoExposureBias", "AutoExposureMinBrightness", "AutoExposureMaxBrightness",
            "AutoExposureMethod", "AutoExposureBiasCurve", "BloomIntensity",
            "VignetteIntensity", "ColorSaturation", "ColorContrast", "ColorGamma",
            "SceneColorTint", "AmbientOcclusionIntensity", "MotionBlurAmount",
            "DepthOfFieldFocalDistance", "SceneFringeIntensity", "FilmGrainIntensity",
            "IndirectLightingIntensity", "WhiteTemp",
        }
        for i, v in ipairs(vols) do
            local info = {}
            pcall(function()
                local fn = v:GetFullName() or ""
                info.name = fn:match("PostProcessVolume_UAID_([^%s]+)$") or fn:match("PersistentLevel%.([^%s]+)") or "?"
            end)
            pcall(function()
                local loc = v:K2_GetActorLocation()
                if loc then info.loc = string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) end
            end)
            -- Bounds v4: Origin/BoxExtent are OUT-PARAMS - UE4SS fills a
            -- passed-in table keyed by param name (proven convention:
            -- GetDisplayVehicle/out_vehicle in headlights.lua). The earlier
            -- reads took Lua RETURN values that never existed. Same logic as
            -- light_cycle's ppPollGT.
            local function takeExtent(oT, xT)
                if not xT then return end
                -- Shapes probed in separate pcalls: a missing field on
                -- userdata ERRORS rather than returning nil.
                local extent
                pcall(function() extent = xT.BoxExtent end)
                if extent == nil then extent = xT end
                pcall(function()
                    info.extent = string.format("%.0f,%.0f,%.0f", extent.X, extent.Y, extent.Z)
                end)
            end
            pcall(function()
                local UEH = nil
                pcall(function() UEH = require("UEHelpers") end)
                local ksl = UEH and UEH.GetKismetSystemLibrary and UEH.GetKismetSystemLibrary()
                if ksl then
                    local oT, xT = {}, {}
                    local r1, r2 = ksl:GetActorBounds(v, oT, xT)
                    takeExtent(oT, xT)
                    if not info.extent then takeExtent(r1, r2) end
                end
            end)
            if not info.extent then
                pcall(function()
                    local oT, xT = {}, {}
                    local r1, r2 = v:GetActorBounds(false, oT, xT, false)
                    takeExtent(oT, xT)
                    if not info.extent then takeExtent(r1, r2) end
                end)
            end
            pcall(function() info.unbound = tostring(v.bUnbound) end)
            pcall(function() info.enabled = tostring(v.bEnabled) end)
            pcall(function()
                local s = v.Settings
                if s then
                    local set = {}
                    for _, flag in ipairs(FLAGS) do
                        local on = nil
                        pcall(function() on = s["bOverride_" .. flag] end)
                        if on == true then
                            local val = nil
                            pcall(function() val = s[flag] end)
                            if type(val) == "number" then
                                set[#set + 1] = flag .. "=" .. string.format("%.3f", val)
                            else
                                set[#set + 1] = flag
                            end
                        end
                    end
                    info.overrides = (#set > 0) and table.concat(set, " ") or "NONE"
                    -- always report the dormant authored bias too
                    pcall(function() info.bias_authored = string.format("%.2f", s.AutoExposureBias) end)
                end
            end)
            Log.Debug(MODULE, "PP volume [" .. i .. "]", info)
        end
    end)

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

    -- (Interior-system probe REMOVED 2026-07-09: verdict was final on
    -- 2026-07-07 - UDS's interior/occlusion family is dead in TXR's cook,
    -- the cache never moves even force-enabled. Tunnels are handled by the
    -- PP-volume containment system in light_cycle instead.)

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
