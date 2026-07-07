-- TXR Weather Mod v3.0
-- systems/light_cycle.lua
-- Sun-elevation-driven exposure/available-light scheduler - the rework of the
-- 144-slot TOD exposure module (systems/exposure.lua, kept intact as fallback
-- behind Config.ModuleToggles.Exposure).
--
-- WHY ELEVATION: stock TXR runs UDS's real solar simulation (Tokyo coords,
-- date pinned 2025-08-13, DST on), so the LIGHT follows the sun's real path -
-- a clock-keyed table is only correct for one date and drifts if the date (or
-- a future season feature) changes. Driving from the sun's actual elevation is
-- season-proof and puts dawn/dusk exactly where the light physically changes:
-- the curve is anchored on real twilight bands (golden hour +6..0 deg, civil
-- twilight 0..-6, night below -10).
--
-- The anchors ship mapped from the 3.3.1 tuned slot table via the measured
-- effective sun events (sunrise ~06:00 / sunset ~19:30 game clock), so the
-- first deploy REPRODUCES the tuned look; where dawn and dusk disagreed at the
-- same |elevation| the dusk tuning won (it had ~30 Alt+D datapoints, dawn few).
-- Tune from Alt+D feedback exactly as before - lines carry sun_elev now.
--
-- Cvar plumbing (game-thread batches, change-detection, skylight-tune
-- overrides, weather multipliers, garage branch, armed gate) is ported from
-- exposure.lua unchanged - it is proven.

local LightCycle = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local State = require("core.state")
local Config = require("config")

-- Lazy-loaded to avoid circular dependencies
local Actors = nil
local TimeOfDay = nil
local UEHelpers = nil

local MODULE = "LightCycle"

-- ============== CONFIG-DERIVED (filled in Init, with safe fallbacks) ==============
local enabled = true
local UPDATE_INTERVAL = 2.0
local CVAR_SKY  = "r.SkylightIntensityMultiplier"
local CVAR_LEAK = "r.Lumen.SkylightLeaking.ReflectionAverageAlbedo"
local CVAR_LENS = "r.EyeAdaptation.LensAttenuation"
local CVAR_ROUGH = "r.Lumen.SkylightLeaking.Roughness"
local TUNE_STEP = 0.05
local ROUGH_BASELINE = 1.0
local LEAK_ALBEDO = 0.07

-- Elevation anchor curve: sorted DESCENDING by elev; piecewise-linear, clamped
-- flat outside the ends. Populated from Config.LightCycle.Curve in Init.
local curve = {}

-- Garage values (no sun there; the scene is artificial light)
local GARAGE_SKY, GARAGE_LENS = 1.005, 30.0

-- Night scene floor: multiplier on UDS "Directional Lights Absent Brightness"
-- (the scene light UDS provides when neither sun nor moon contributes). 1.0 =
-- leave stock. One-shot per course, scaled from the freshly-spawned stock value
-- (never compounds), logged stock->new.
local ABSENT_MULT = 1.0
local PROP_ABSENT_BRIGHTNESS = "Directional Lights Absent Brightness"

-- Sun vector property (FVector, updated by UDS every frame)
local PROP_SUN_VECTOR = "Cached Sun Vector"

-- Interior probe (temporary, Config.LightCycle.ProbeInterior): watch UDS's
-- interior-occlusion cache while driving. If it moves in tunnels, TXR wired
-- UDS's occlusion system and the native interior adjustments (tunnel exposure/
-- light multipliers) are potentially usable; if it never moves, that whole
-- family is dead here. Logs only on change - drive through a tunnel to test.
local PROP_OCCLUSION = "Cached Inverted Global Occlusion"
local PROBE_INTERIOR = false
local lastOcclusion = nil

-- Pseudo-elevation fallback (also calibrates the vector sign): effective sun
-- events measured on the stock install (DST-shifted): sunrise 06:00, sunset
-- 19:30 game clock.
local SUNRISE_TOD, SUNSET_TOD = 600.0, 1930.0

-- ============== STATE ==============
local isInitialized = false
local lastCheckClock = 0.0
local lastLens = nil                 -- brightness proxy for headlights (GetBrightnessLens)
local lastElevation = nil            -- last computed sun elevation (degrees)
local elevSign = nil                 -- +1/-1 once calibrated against the pseudo curve
local usedPseudoLogged = false
local lastApplied = { sky = nil, leak = nil, lens = nil }
local armed = false                  -- course gate (see exposure.lua notes: fresh UDS
                                     -- reads garbage before the restore has run)
local absentApplied = false          -- one-shot flag for the night-floor mult

-- Skylight tuning overrides (Alt+Z/X/C): identical semantics to exposure.lua
local tune = { sky = nil, leak = nil, rough = nil }
local TUNE_LIMITS = {
    sky   = { min = 0.0, max = 4.0, fallback = 1.0 },
    leak  = { min = 0.0, max = 1.0, fallback = 0.07 },
    rough = { min = 0.0, max = 1.0 },
}

-- Per-weather compensation (smoothed) - ported from exposure.lua
local WEATHER_MULT = {}
local WEATHER_SKY_MULT = {}
local MULT_SMOOTH_SECONDS = 20.0
local weatherMult = 1.0
local weatherSkyMult = 1.0
local lastMultClock = nil

-- ============== INTERNAL: shared helpers (ported from exposure.lua) ==============

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

local function getUEHelpers()
    if not UEHelpers then
        pcall(function() UEHelpers = require("UEHelpers") end)
    end
    return UEHelpers
end

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function lerp(a, b, t) return a + (b - a) * t end

local cachedEngine = nil
local cachedKsl = nil

local function validRef(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function getEngineRef()
    if validRef(cachedEngine) then return cachedEngine end
    local eng = nil
    pcall(function() eng = FindFirstOf("Engine") end)
    if validRef(eng) then cachedEngine = eng; return eng end
    return nil
end

local function getKslRef()
    if validRef(cachedKsl) then return cachedKsl end
    local UEH = getUEHelpers()
    if not UEH or not UEH.GetKismetSystemLibrary then return nil end
    local ksl = nil
    pcall(function() ksl = UEH.GetKismetSystemLibrary() end)
    if validRef(ksl) then cachedKsl = ksl; return ksl end
    return nil
end

local execBatches = 0
local dropBatches = 0
local execLoggedOnce = false
local cmdErrWarned = false
local function scheduleExec(cmds)
    if not cmds or #cmds == 0 then return false end
    local run = function()
        local ksl = getKslRef()
        local eng = getEngineRef()
        if not ksl or not eng then
            dropBatches = dropBatches + 1
            if dropBatches == 1 or dropBatches % 50 == 0 then
                Log.Warn(MODULE, "Cvar batch DROPPED - Engine/KSL unavailable at run time",
                    {drops = dropBatches, ksl = ksl ~= nil, eng = eng ~= nil})
            end
            return
        end
        local allOk = true
        for _, cmd in ipairs(cmds) do
            local ok = pcall(function() ksl:ExecuteConsoleCommand(eng, cmd, nil) end)
            if not ok then allOk = false end
        end
        execBatches = execBatches + 1
        if not execLoggedOnce then
            execLoggedOnce = true
            Log.Info(MODULE, "First cvar batch EXECUTED on game thread", {cmds = #cmds})
        end
        if not allOk and not cmdErrWarned then
            cmdErrWarned = true
            Log.Warn(MODULE, "ExecuteConsoleCommand errored for at least one cvar push")
        end
    end
    if ExecuteInGameThread then
        return pcall(function() ExecuteInGameThread(run) end)
    end
    run()
    return true
end

local lastDriveState = nil
local function noteDriveState(state)
    if state == lastDriveState then return end
    lastDriveState = state
    local tag = "?"
    local actors = getActors()
    if actors and actors.GetWorldTag then
        pcall(function() tag = actors.GetWorldTag() or "?" end)
    end
    Log.Info(MODULE, "Drive state: " .. state, {world = tag})
end

--- Push the cvar trio; skips values unchanged since the last push.
local function applyValues(sky, leak, lens, elev, reason)
    local eps = 1e-4
    if tune.sky  then sky  = tune.sky  end
    if tune.leak then leak = tune.leak end
    local cmds = {}
    if not lastApplied.sky  or math.abs(sky  - lastApplied.sky)  >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_SKY,  sky)
    end
    if not lastApplied.leak or math.abs(leak - lastApplied.leak) >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LEAK, leak)
    end
    if not lastApplied.lens or math.abs(lens - lastApplied.lens) >= eps then
        cmds[#cmds + 1] = string.format("%s %.6f", CVAR_LENS, lens)
    end
    if #cmds == 0 then return true end

    local scheduled = scheduleExec(cmds)
    lastApplied.sky, lastApplied.leak, lastApplied.lens = sky, leak, lens

    Log.Info(MODULE, "Applied light", {
        sun_elev = elev and string.format("%.1f", elev) or "nil",
        reason = reason or "",
        sky = sky, leak = leak, lens = lens,
        scheduled = scheduled,
    })
    return scheduled
end

-- ============== INTERNAL: sun elevation ==============

--- Approximate elevation from the game clock (fallback + sign calibration).
--- Sinusoidal arc between the measured effective sun events; peaks ~+75 deg
--- (Tokyo mid-August), bottoms ~-55 deg.
local function pseudoElevation(tod)
    if tod == nil then return nil end
    tod = tod % 2400
    if tod >= SUNRISE_TOD and tod <= SUNSET_TOD then
        local p = (tod - SUNRISE_TOD) / (SUNSET_TOD - SUNRISE_TOD)
        return 75.0 * math.sin(math.pi * p)
    end
    local nightLen = 2400 - (SUNSET_TOD - SUNRISE_TOD)
    local since = (tod - SUNSET_TOD) % 2400
    local p = since / nightLen
    return -55.0 * math.sin(math.pi * p)
end

--- Real elevation from UDS's cached sun vector. The vector's vertical sign
--- convention is not documented, so it is calibrated ONCE against the pseudo
--- curve at a moment when the pseudo value is decisive (|elev| >= 15 deg).
--- Returns nil when the vector is unavailable.
local function readSunElevation(uds, tod)
    local x, y, z = nil, nil, nil
    pcall(function()
        local v = uds[PROP_SUN_VECTOR]
        if v then x, y, z = v.X, v.Y, v.Z end
    end)
    if type(z) ~= "number" then return nil end
    local mag = math.sqrt((x or 0) ^ 2 + (y or 0) ^ 2 + z ^ 2)
    if mag < 0.5 then return nil end
    local raw = math.deg(math.asin(clamp(z / mag, -1.0, 1.0)))

    if elevSign == nil then
        local pseudo = pseudoElevation(tod)
        if pseudo and math.abs(pseudo) >= 15.0 and math.abs(raw) >= 2.0 then
            elevSign = ((raw >= 0) == (pseudo >= 0)) and 1 or -1
            Log.Info(MODULE, "Sun vector sign calibrated", {
                sign = elevSign, raw = string.format("%.1f", raw),
                pseudo = string.format("%.1f", pseudo),
            })
        end
    end
    if elevSign == nil then return nil end
    return raw * elevSign
end

--- Piecewise-linear lookup on the elevation anchor curve.
--- @return number sky, number lens
local function curveLookup(elev)
    local n = #curve
    if n == 0 then return 0.10, 1.0 end
    if elev >= curve[1].elev then return curve[1].sky, curve[1].lens end
    if elev <= curve[n].elev then return curve[n].sky, curve[n].lens end
    for i = 1, n - 1 do
        local a, b = curve[i], curve[i + 1]
        if elev <= a.elev and elev >= b.elev then
            local t = (a.elev - elev) / (a.elev - b.elev)
            return lerp(a.sky, b.sky, t), lerp(a.lens, b.lens, t)
        end
    end
    return curve[n].sky, curve[n].lens
end

--- One-shot night scene floor: scale "Directional Lights Absent Brightness"
--- from the fresh actor's stock value (fresh per course, never compounds).
local function applyAbsentBrightness(uds)
    if absentApplied then return end
    absentApplied = true
    if not ABSENT_MULT or math.abs(ABSENT_MULT - 1.0) < 1e-3 then return end
    local stock = nil
    pcall(function() stock = uds[PROP_ABSENT_BRIGHTNESS] end)
    stock = tonumber(stock)
    if stock == nil then
        Log.Warn(MODULE, "Night floor: stock read failed (skipping)", {prop = PROP_ABSENT_BRIGHTNESS})
        return
    end
    local new = stock * ABSENT_MULT
    local ok = pcall(function() uds[PROP_ABSENT_BRIGHTNESS] = new end)
    if ok then
        Log.Info(MODULE, "Night scene floor applied", {
            stock = string.format("%.4f", stock),
            new = string.format("%.4f", new),
            mult = ABSENT_MULT,
        })
    else
        Log.Warn(MODULE, "Night floor: write failed", {prop = PROP_ABSENT_BRIGHTNESS})
    end
end

-- ============== PUBLIC API ==============

function LightCycle.Init()
    if isInitialized then return true end

    local cfg = Config.LightCycle
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.UpdateIntervalSeconds then UPDATE_INTERVAL = cfg.UpdateIntervalSeconds end
        if cfg.LeakAlbedo then LEAK_ALBEDO = cfg.LeakAlbedo end
        if type(cfg.Curve) == "table" then curve = cfg.Curve end
        if cfg.Garage then
            if cfg.Garage.Sky then GARAGE_SKY = cfg.Garage.Sky end
            if cfg.Garage.Lens then GARAGE_LENS = cfg.Garage.Lens end
        end
        if cfg.AbsentBrightnessMult then ABSENT_MULT = cfg.AbsentBrightnessMult end
        if cfg.ProbeInterior ~= nil then PROBE_INTERIOR = cfg.ProbeInterior end
        if cfg.SunriseTOD then SUNRISE_TOD = cfg.SunriseTOD end
        if cfg.SunsetTOD then SUNSET_TOD = cfg.SunsetTOD end
        if type(cfg.WeatherLensMult) == "table" then WEATHER_MULT = cfg.WeatherLensMult end
        if type(cfg.WeatherSkyMult) == "table" then WEATHER_SKY_MULT = cfg.WeatherSkyMult end
        if cfg.WeatherSmoothSeconds then MULT_SMOOTH_SECONDS = cfg.WeatherSmoothSeconds end
        if type(cfg.Tune) == "table" then
            if cfg.Tune.Step then TUNE_STEP = cfg.Tune.Step end
            if cfg.Tune.RoughnessBaseline then ROUGH_BASELINE = cfg.Tune.RoughnessBaseline end
        end
    end

    -- Sort anchors descending by elevation so the lookup can assume order
    table.sort(curve, function(a, b) return a.elev > b.elev end)

    isInitialized = true
    State.SetModuleStatus("light_cycle", true)

    if not enabled then
        Log.Info(MODULE, "Light cycle module disabled in config")
        return true
    end

    Log.Info(MODULE, "Initializing light cycle module", {
        anchors = #curve,
        intervalSec = UPDATE_INTERVAL,
        absentMult = ABSENT_MULT,
    })
    return true
end

--- True when this module is the active exposure provider (keybinds/headlights
--- route here instead of the legacy exposure module). Checks the module toggle
--- too: consumers require() this file directly, bypassing main.lua's nil-ing,
--- so without the check a toggled-off (never-ticking) module would still
--- capture the Alt+D family and the headlight brightness proxy.
function LightCycle.IsActive()
    if not (isInitialized and enabled) then return false end
    local tg = Config.ModuleToggles
    if tg and tg.LightCycle == false then return false end
    return true
end

function LightCycle.OnCourseLoad()
    lastCheckClock = 0.0
    lastApplied.sky, lastApplied.leak, lastApplied.lens = nil, nil, nil
    lastLens = nil
    lastElevation = nil
    absentApplied = false
    armed = true
end

function LightCycle.OnCourseUnload()
    armed = false
end

--- Per-tick update (throttled to UPDATE_INTERVAL).
function LightCycle.Update()
    if not enabled then return true end

    local now = os.clock()
    if (now - lastCheckClock) < UPDATE_INTERVAL then return true end
    lastCheckClock = now

    local actors = getActors()
    if not actors then return true end

    -- Garage / PA-menu worlds: fixed artificial-light values (no sun there).
    if actors.IsInGarage and actors.IsInGarage() then
        noteDriveState("garage")
        lastLens = GARAGE_LENS
        applyValues(GARAGE_SKY, LEAK_ALBEDO, GARAGE_LENS, nil, "garage")
        return true
    end

    if not armed then
        noteDriveState("idle (not garage, course not armed)")
        return true
    end

    local uds = actors.GetUDS and actors.GetUDS()
    if not uds then
        noteDriveState("armed, no UDS")
        return true
    end

    local tod = nil
    local t = getTimeOfDay()
    if t then
        local ok, v = pcall(t.GetCurrentTOD)
        if ok then tod = v end
    end

    -- Sun elevation: real vector when available, pseudo (clock) fallback until
    -- the sign is calibrated / when the vector read fails.
    local elev = readSunElevation(uds, tod)
    if elev == nil then
        elev = pseudoElevation(tod)
        if elev ~= nil and not usedPseudoLogged then
            usedPseudoLogged = true
            Log.Info(MODULE, "Using pseudo elevation (sun vector not readable yet)")
        end
    end
    if elev == nil then
        noteDriveState("armed, no elevation")
        return true
    end
    lastElevation = elev

    local sky, lens = curveLookup(elev)

    -- Weather compensation (smoothed toward the preset's targets)
    local target, skyTarget = 1.0, 1.0
    local preset = nil
    pcall(function() preset = State.GetCurrentPreset() end)
    if preset then
        if WEATHER_MULT[preset] then target = WEATHER_MULT[preset] end
        if WEATHER_SKY_MULT[preset] then skyTarget = WEATHER_SKY_MULT[preset] end
    end
    local dtm = 0.5
    if lastMultClock then dtm = clamp(now - lastMultClock, 0.0, 5.0) end
    lastMultClock = now
    if MULT_SMOOTH_SECONDS > 0 then
        local blend = clamp(dtm / MULT_SMOOTH_SECONDS, 0.0, 1.0)
        weatherMult = weatherMult + (target - weatherMult) * blend
        weatherSkyMult = weatherSkyMult + (skyTarget - weatherSkyMult) * blend
    else
        weatherMult = target
        weatherSkyMult = skyTarget
    end
    lens = lens * weatherMult
    sky = sky * weatherSkyMult

    noteDriveState("course")
    lastLens = lens
    applyValues(sky, LEAK_ALBEDO, lens, elev, "elevation")

    -- Night scene floor one-shot (needs a valid UDS; harmless if mult is 1.0)
    applyAbsentBrightness(uds)

    -- Interior-occlusion probe (see PROBE_INTERIOR note above)
    if PROBE_INTERIOR then
        local occ = nil
        pcall(function() occ = uds[PROP_OCCLUSION] end)
        occ = tonumber(occ)
        if occ ~= nil and (lastOcclusion == nil or math.abs(occ - lastOcclusion) > 0.05) then
            Log.Info(MODULE, "Interior occlusion", {
                value = string.format("%.3f", occ),
                was = lastOcclusion and string.format("%.3f", lastOcclusion) or "nil",
                sun_elev = elev and string.format("%.1f", elev) or "nil",
            })
            lastOcclusion = occ
        end
    end

    return true
end

--- Brightness proxy for the headlights module (same scale as the legacy
--- exposure module: ~1.0 bright day .. ~30 deep night).
function LightCycle.GetBrightnessLens()
    return lastLens
end

--- Last computed sun elevation in degrees (nil before the first course tick).
function LightCycle.GetSunElevation()
    return lastElevation
end

-- ============== FEEDBACK + SKYLIGHT TUNING (Alt+D family) ==============

local function captureContext()
    local tod, todStr = nil, "--:--"
    local t = getTimeOfDay()
    if t then
        local ok, v = pcall(t.GetCurrentTOD)
        if ok then tod = v end
        if t.FormatTime then pcall(function() todStr = t.FormatTime(tod) end) end
    end

    local preset = "unknown"
    pcall(function() preset = State.GetCurrentPreset() or "none" end)

    local where = "unknown"
    local actors = getActors()
    if actors then
        if actors.IsInGarage and actors.IsInGarage() then
            where = "garage"
        elseif actors.GetWorldTag then
            pcall(function() where = actors.GetWorldTag() or "unknown" end)
        end
    end

    return tod, todStr, preset, where
end

--- @param direction string "dark" | "bright"
function LightCycle.LogFeedback(direction)
    local tod, todStr, preset, where = captureContext()

    Log.Info("ExposureTune", "FEEDBACK too-" .. tostring(direction), {
        verdict      = direction,
        time         = todStr,
        tod          = tod and string.format("%.0f", tod) or "nil",
        sun_elev     = lastElevation and string.format("%.1f", lastElevation) or "nil",
        driver       = "elevation",
        weather      = preset,
        where        = where,
        applied_sky  = lastApplied.sky,
        applied_leak = lastApplied.leak,
        applied_lens = lastApplied.lens,
        interp_lens  = lastLens,
        weather_mult = weatherMult,
        weather_sky_mult = weatherSkyMult,
    })
end

--- @param which string "sky" | "leak" | "rough"
--- @param dir number +1 | -1
function LightCycle.NudgeSkylight(which, dir)
    local lim = TUNE_LIMITS[which]
    if not lim then
        Log.Warn(MODULE, "NudgeSkylight: unknown cvar key", {which = tostring(which)})
        return
    end

    local cur = tune[which]
    if cur == nil then
        if which == "rough" then
            cur = ROUGH_BASELINE
        else
            cur = lastApplied[which] or lim.fallback
        end
    end

    local new = clamp(cur + dir * TUNE_STEP, lim.min, lim.max)
    if new == cur then return end

    tune[which] = new

    local cvar = (which == "sky" and CVAR_SKY) or (which == "leak" and CVAR_LEAK) or CVAR_ROUGH
    scheduleExec({ string.format("%s %.6f", cvar, new) })
    if which ~= "rough" then lastApplied[which] = new end

    Log.Info("SkylightTune", "NUDGE " .. which .. (dir > 0 and " +" or " -"), {
        value = new,
        sun_elev = lastElevation and string.format("%.1f", lastElevation) or "nil",
    })
end

--- Log a confirmed-good skylight datapoint (Alt+V).
function LightCycle.LogSkylightConfirm()
    local tod, todStr, preset, where = captureContext()
    Log.Info("SkylightTune", "DATAPOINT", {
        time = todStr,
        tod = tod and string.format("%.0f", tod) or "nil",
        sun_elev = lastElevation and string.format("%.1f", lastElevation) or "nil",
        weather = preset,
        where = where,
        sky = tune.sky or lastApplied.sky,
        leak = tune.leak or lastApplied.leak,
        rough = tune.rough or ROUGH_BASELINE,
        lens = lastApplied.lens,
    })
end

--- Clear the skylight tuning overrides (Alt+Shift+V): back to the curve.
function LightCycle.ResetSkylightTune()
    tune.sky, tune.leak, tune.rough = nil, nil, nil
    -- Force a fresh push of curve values on the next update
    lastApplied.sky, lastApplied.leak, lastApplied.lens = nil, nil, nil
    lastCheckClock = 0.0
    scheduleExec({ string.format("%s %.6f", CVAR_ROUGH, ROUGH_BASELINE) })
    Log.Info("SkylightTune", "RESET to curve")
end

function LightCycle.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        armed = armed,
        sunElevation = lastElevation,
        elevSign = elevSign,
        lastApplied = lastApplied,
        weatherMult = weatherMult,
        weatherSkyMult = weatherSkyMult,
        execBatches = execBatches,
        dropBatches = dropBatches,
    }
end

function LightCycle.IsInitialized()
    return isInitialized
end

--- Alias so the module can be ticked as either Tick() or Update().
LightCycle.Tick = LightCycle.Update

return LightCycle
