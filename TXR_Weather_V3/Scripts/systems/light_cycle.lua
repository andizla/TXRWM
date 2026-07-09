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

-- PA continue/freeze (Config.PA.Mode ~= "stock"): the PA scene follows the
-- normal elevation path instead of the garage constants (set in Init).
local PA_FOLLOW = false

-- Night scene floor: multiplier on UDS "Directional Lights Absent Brightness"
-- (the scene light UDS provides when neither sun nor moon contributes). 1.0 =
-- leave stock. One-shot per course, scaled from the freshly-spawned stock value
-- (never compounds), logged stock->new.
local ABSENT_MULT = 1.0
local PROP_ABSENT_BRIGHTNESS = "Directional Lights Absent Brightness"

-- Cloudy-night scene floor: ABSOLUTE value for "Extra Night Brightness When
-- Cloudy" (stock ships 0.0 - a multiplier would have nothing to scale).
-- nil = leave stock. Applied in the same per-course one-shot.
local NIGHT_CLOUDY = nil
local PROP_NIGHT_CLOUDY = "Extra Night Brightness When Cloudy"

-- Overcast night keep-fraction: ABSOLUTE for "Overcast Brightness (Night)"
-- (stock 0.2 - how much light survives under full cloud at night). nil = stock.
local OVERCAST_NIGHT = nil
local PROP_OVERCAST_NIGHT = "Overcast Brightness Night"

-- Dawn damping: the anchor curve is dusk-tuned and dawn reads brighter at the
-- same elevation. While the sun is RISING, sky/lens scale by these multipliers,
-- feathered across the transition band (zero at the edges, full inside) so the
-- damping never steps. 1.0 = symmetric curve.
local DAWN_SKY_MULT = 1.0
local DAWN_LENS_MULT = 1.0
local prevElevSample = nil

-- Sun vector property (FVector, updated by UDS every frame)
local PROP_SUN_VECTOR = "Cached Sun Vector"

-- (Interior-occlusion probe REMOVED 2026-07-09: UDS's interior family is
-- confirmed dead in TXR's cook - the PP-volume containment system below is
-- the tunnel mechanism.)

-- TEMPORARY PP-volume watcher (Config.LightCycle.ProbePPVolumes): the course
-- carries 33 bounded PostProcessVolumes with authored-but-inert exposure
-- biases (override flags false at settle). If the game drives them at runtime
-- (tunnel/area grading), flags or values change - poll on the game thread
-- every ~5s and log diffs. Refs are per-course; cleared on unload, and both
-- sides re-check the teardown window (cached cross-world refs are the known
-- crash pattern).
local PROBE_PP = false
local ppRefs = nil
local ppNextPoll = 0.0

-- TUNNEL FEATURES v2 (2026-07-09, retuned from the 00:37 capture readout):
-- while the pawn is inside a confirmed tunnel volume, (a) trim the bias
-- output - the fix for "daytime tunnels weirdly bright" under stock
-- auto-exposure - and (b) suppress rain particles (it IS still raining
-- outside the tunnel). Volumes matched by NAME (FindAllOf index order not
-- trusted). Trim = -TrimScale * authoredBias * dayWeight:
--   authoredBias = the volume's dev-authored dormant AutoExposureBias (the
--     devs' own coveredness map; 0.5..0.8 on the confirmed bores) - free
--     per-tunnel differentiation, max across overlapping volumes;
--   dayWeight feathers 0->1 across sun elev FadeLow..FadeHigh - night
--     tunnels are FINE stock (user verdict), so no trim below the horizon
--     and no step at dusk.
-- Flat v1 (-1.0 all day) measured only ~17% darker on screen post-tonemap
-- (YAVG 94->78) = "little to no change"; scale 3.0 gives the Kasumigaseki
-- bore -2.1 EV at midday.
-- Rain kill keys on (car inside OR ~1.2s velocity-lookahead inside) so the
-- kill lands AT the portal instead of a poll late; the trim keys on the car
-- position only.
local TUNNEL_VOLUMES = {}        -- set: [shortName] = true (curated bores)
local TUNNEL_AUTO = true         -- ALSO treat any volume with authored bias >
                                 -- min as covered (user call 2026-07-09: the
                                 -- devs' own list, fills the un-ID'd bores at
                                 -- the cost of also treating trenches)
local TUNNEL_AUTO_MIN = 0.05     -- authored-bias threshold for auto membership
local TUNNEL_TRIM_SCALE = 3.7    -- trim = -scale * authoredBias * dayWeight
                                 -- (3.0 verdict: "could be ~0.5 darker still")
local TUNNEL_FADE_LOW = 0.0      -- sun elev (deg): trim zero at/below this
local TUNNEL_FADE_HIGH = 12.0    -- ...full at/above this
local TUNNEL_RAIN_KILL = true
local TUNNEL_LOOKAHEAD_S = 1.2   -- rain-kill lookahead seconds
local TUNNEL_ACTIVE = false      -- computed in Init: membership + a feature on
local tunnelNow = false          -- car inside a tunnel volume (drives the trim)
local rainZoneNow = false        -- car or lookahead inside (drives the rain kill)
local curTunnelAuthored = 0.0    -- max authored bias among volumes we're inside
local lastPX, lastPY, lastPZ, lastPollClock = nil, nil, nil, nil
-- Snap: UDS lerps its bias knobs over ~4s (measured on the 00:37 capture) -
-- too slow for a portal ("clearly not fast enough. 1s is enough"). On tunnel
-- transitions the first write OVERSHOOTS by SNAP_K so the lerp crosses the
-- true target in ~1s; a clear pass then writes the exact value.
local SNAP_K = 2.0
local snapClearAt = nil          -- os.clock() when the overshoot gets corrected

-- OUTPUT MODE (2026-07-08, post-breakthrough): "bias" drives UDS's five
-- Exposure Bias knobs (user-confirmed live: smooth native application to the
-- composited pipeline) on top of stock auto-exposure; cvars pushed once at
-- engine-neutral. "cvars" = the legacy elevation->cvar curve (fallback; needs
-- MethodOverride=3 restored in engine.ini to look right). In bias mode the
-- legacy Curve still runs internally as the HEADLIGHT brightness proxy only
-- (keeps the tuned OnLens/OffLens thresholds meaningful).
local OUTPUT_MODE = "bias"
local BIAS_CURVE = {}
local lastBias = nil
local scenarioZeroed = false
-- Weather bias: adaptation self-normalizes weather brightness, so this ships
-- OFF (0.0). Raising it re-adds old-style compensation as EV:
-- bias += log2(1 + (WeatherSkyMult-1) * nightWeight) * scale.
local WEATHER_BIAS_SCALE = 0.0

-- DIAGNOSTIC neutral-cvars mode (Config.LightCycle.DiagnosticNeutralCvars):
-- pushes engine-neutral values (sky 1.0, lens 0.78 = UE physical default,
-- leak unchanged) instead of the curve, everywhere incl. the garage - the
-- picture then shows RAW UDS light + the source-lever one-shots with nothing
-- from the exposure layer masking it. Elevation keeps logging ("Diag
-- elevation") so captures stay mappable. Headlight auto falls back to its
-- TOD thresholds (the lens proxy goes nil). TEMPORARY - testing only.
local DIAGNOSTIC = false
local DIAG_SKY, DIAG_LENS = 1.0, 0.78
local lastDiagElev = nil

-- NOTE: ppPollGT/ppWatchTick (the PP-volume watcher bodies) live BELOW the
-- UEH/KSL helper definitions - see the ordering note there.

-- Pseudo-elevation fallback (also calibrates the vector sign): effective sun
-- events measured on the stock install (DST-shifted): sunrise 06:00, sunset
-- 19:30 game clock.
local SUNRISE_TOD, SUNSET_TOD = 600.0, 1930.0

-- ============== STATE ==============
local isInitialized = false
local lastCheckClock = 0.0
local lastLens = nil                 -- brightness proxy for headlights (GetBrightnessLens)
local lastElevation = nil            -- last computed sun elevation (degrees)

-- UDS sun-vector vertical convention: the cached vector is the LIGHT direction,
-- so raw Z = -sin(elevation) and the sign is a CONSTANT -1 (measured across
-- sessions: Nov midday raw=-39 with real +39; a full inverted December day when
-- v1's auto-calibration latched +1). Auto-calibration was removed because it
-- RACED the course-load restore: the vector cache still held the pre-restore
-- midnight sky while the clock already read 08:00 - one bad latch inverted the
-- whole session (night exposure at noon). Config.LightCycle.SunVectorSign
-- overrides if a UDS update ever flips the convention; a trusted-window sanity
-- check WARNS on persistent disagreement but never auto-flips.
local SUN_VECTOR_SIGN = -1
local signViolations = 0
local signWarned = false
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
local lastNightWeight = 1.0   -- elevation weighting applied to the weather mults

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

-- ============== PP-VOLUME WATCHER (containment) ==============
-- MOVED HERE 2026-07-08: defined ABOVE getUEHelpers/getKslRef, the calls to
-- them inside ppPollGT compiled as NIL GLOBALS and errored silently inside
-- pcall (the same local-ordering footgun that killed ppWatchTick once) - so
-- the pawn-location read never ran (containment blind regardless of bounds)
-- and the KSL bounds attempt never executed at all.
local ppInside = {}   -- [index] = true while the pawn is inside that volume
local ppShapeLogged = false  -- one-shot out-table diagnostic if capture fails

local Weather = nil
local function getWeather()
    if not Weather then
        local ok, mod = pcall(require, "systems.weather")
        if ok then Weather = mod end
    end
    return Weather
end

--- Pure-state tunnel reset (refs dropped: unload/teardown/re-arm). NO
--- weather calls - safe from any thread; the next Weather.Apply clears any
--- lingering suppression itself (full restore path, see weather.lua).
local function tunnelReset()
    tunnelNow, rainZoneNow, curTunnelAuthored = false, false, 0.0
    lastPX, lastPY, lastPZ, lastPollClock = nil, nil, nil, nil
end

--- Apply the tunnel state computed by the containment poll (game thread).
--- The trim keys on the car being inside; the rain kill additionally
--- accepts the lookahead point so the kill lands at the portal. Bias
--- refresh via the LightCycle table field (defined later in the file,
--- resolved at call time).
local function tunnelApplyState(carIn, lookIn, maxAuthored)
    curTunnelAuthored = maxAuthored or 0.0
    if carIn ~= tunnelNow then
        tunnelNow = carIn
        if carIn then
            Log.Info(MODULE, "Tunnel trim ON", {authored = string.format("%.2f", curTunnelAuthored)})
        else
            Log.Info(MODULE, "Tunnel trim OFF")
        end
        if LightCycle._TunnelBiasRefresh then pcall(LightCycle._TunnelBiasRefresh, true) end
    end
    local wantKill = (TUNNEL_RAIN_KILL and (carIn or lookIn)) or false
    if wantKill ~= rainZoneNow then
        rainZoneNow = wantKill
        pcall(function()
            local W = getWeather()
            if W and W.SetPrecipSuppressed then W.SetPrecipSuppressed(wantKill) end
        end)
    elseif wantKill then
        -- A weather change mid-tunnel (Weather.Apply) clears the suppression
        -- without telling us - re-assert whenever the actual state disagrees,
        -- so rain can't run inside a tunnel until the next ENTER.
        pcall(function()
            local W = getWeather()
            if W and W.IsPrecipSuppressed and not W.IsPrecipSuppressed() then
                W.SetPrecipSuppressed(true)
            end
        end)
    end
end

local function ppPollGT()
    local actors = Actors
    if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
        ppRefs = nil
        ppInside = {}
        tunnelReset()
        return
    end
    if not ppRefs then
        ppRefs = {}
        ppInside = {}
        tunnelReset()
        pcall(function()
            local vols = FindAllOf("PostProcessVolume")
            if not vols then return end
            for _, v in ipairs(vols) do
                local e = { v = v }
                pcall(function()
                    local s = v.Settings
                    e.biasNum = tonumber(s.AutoExposureBias) or 0.0
                    e.bias = tostring(s.AutoExposureBias)
                end)
                -- Short name (same extraction as real_sun's ID dump) - the
                -- stable key for the config tunnel list.
                pcall(function()
                    local fn = v:GetFullName() or ""
                    e.name = fn:match("PostProcessVolume_UAID_([^%s]+)$")
                        or fn:match("PersistentLevel%.([^%s]+)")
                end)
                if (e.name and TUNNEL_VOLUMES[e.name])
                    or (TUNNEL_AUTO and (e.biasNum or 0) > TUNNEL_AUTO_MIN) then
                    e.isTunnel = true
                end
                -- Bounds capture v4: Origin/BoxExtent are OUT-PARAMS, and
                -- UE4SS hands those back by FILLING a passed-in Lua table
                -- keyed by the param name - the convention already proven in
                -- this mod (GetDisplayVehicle/out_vehicle, GetIsMovingRHL/
                -- out_is_moving in headlights.lua). Attempts 1-3 read Lua
                -- RETURN values that never existed. Accepts every plausible
                -- shape: param-name key holding an FVector, fields written
                -- straight into the table, or true return values.
                local function takeBounds(oT, xT)
                    if not (oT and xT) then return end
                    -- Each shape probed in its OWN pcall: indexing a missing
                    -- field on userdata ERRORS (does not return nil), so a
                    -- combined read would abort before trying the next shape.
                    local origin, extent
                    pcall(function() origin = oT.Origin end)
                    if origin == nil then origin = oT end
                    pcall(function() extent = xT.BoxExtent end)
                    if extent == nil then extent = xT end
                    local ox, oy, oz, ex, ey, ez
                    pcall(function()
                        ox, oy, oz = origin.X, origin.Y, origin.Z
                        ex, ey, ez = extent.X, extent.Y, extent.Z
                    end)
                    if ox and ex then
                        e.ox, e.oy, e.oz = ox, oy, oz
                        e.ex, e.ey, e.ez = ex, ey, ez
                    end
                end
                pcall(function()
                    local ksl = getKslRef()
                    if ksl then
                        local oT, xT = {}, {}
                        local r1, r2 = ksl:GetActorBounds(v, oT, xT)
                        takeBounds(oT, xT)
                        if not e.ox then takeBounds(r1, r2) end
                    end
                end)
                if not e.ox then
                    pcall(function()
                        local oT, xT = {}, {}
                        local r1, r2 = v:GetActorBounds(false, oT, xT, false)
                        takeBounds(oT, xT)
                        if not e.ox then takeBounds(r1, r2) end
                    end)
                end
                -- If v4 fails too, log what UE4SS actually put in the out
                -- tables (once) so the next log settles the convention
                -- instead of a fourth silent failure.
                if not e.ox and not ppShapeLogged then
                    ppShapeLogged = true
                    pcall(function()
                        local oT, xT = {}, {}
                        local ksl = getKslRef()
                        if ksl then ksl:GetActorBounds(v, oT, xT) end
                        local keys = {}
                        for k, val in pairs(oT) do keys[#keys + 1] = "o." .. tostring(k) .. "=" .. type(val) end
                        for k, val in pairs(xT) do keys[#keys + 1] = "x." .. tostring(k) .. "=" .. type(val) end
                        Log.Info(MODULE, "Bounds shape debug",
                            {keys = (#keys > 0) and table.concat(keys, " ") or "BOTH EMPTY"})
                    end)
                end
                ppRefs[#ppRefs + 1] = e
            end
            local withBounds, tunnels = 0, 0
            for _, e2 in ipairs(ppRefs) do
                if e2.ox then withBounds = withBounds + 1 end
                if e2.isTunnel then tunnels = tunnels + 1 end
            end
            Log.Info(MODULE, "PP watcher armed", {volumes = #ppRefs, withBounds = withBounds, tunnels = tunnels})
        end)
        return
    end

    -- Containment: which volume is the car inside right now? ENTER/EXIT logs
    -- identify tunnel volumes as the user simply drives around.
    local px, py, pz = nil, nil, nil
    pcall(function()
        local UEH = getUEHelpers()
        local pc = UEH and UEH.GetPlayerController and UEH.GetPlayerController()
        local pawn = pc and pc.Pawn
        if pawn and pawn.IsValid and pawn:IsValid() then
            local loc = pawn:K2_GetActorLocation()
            if loc then px, py, pz = loc.X, loc.Y, loc.Z end
        end
    end)
    if px == nil then return end

    local carIn, maxAuth = false, 0.0
    for i, e in ipairs(ppRefs) do
        if e.ox then
            local inside = math.abs(px - e.ox) <= e.ex
                and math.abs(py - e.oy) <= e.ey
                and math.abs(pz - e.oz) <= e.ez
            if inside and e.isTunnel then
                carIn = true
                if (e.biasNum or 0) > maxAuth then maxAuth = e.biasNum or 0 end
            end
            if inside and not ppInside[i] then
                ppInside[i] = true
                Log.Info(MODULE, "PP volume ENTER [" .. i .. "]", {
                    name = e.name or "?",
                    tunnel = e.isTunnel and "YES" or nil,
                    bias_authored = e.bias,
                    extent = string.format("%.0f,%.0f,%.0f", e.ex, e.ey, e.ez),
                })
            elseif not inside and ppInside[i] then
                ppInside[i] = nil
                Log.Info(MODULE, "PP volume EXIT [" .. i .. "]", {name = e.name or "?"})
            end
        end
    end

    -- Rain-kill lookahead: project the car ~TUNNEL_LOOKAHEAD_S ahead using
    -- the position delta between polls (no reflection dependency), clamped
    -- to 120 m so a course-restart teleport can't produce a wild point.
    -- Only needed while still outside (carIn already suppresses).
    local lookIn = false
    local nowC = os.clock()
    if TUNNEL_RAIN_KILL and not carIn then
        local lx, ly, lz = px, py, pz
        if lastPX and lastPollClock and nowC > lastPollClock then
            local sc = TUNNEL_LOOKAHEAD_S / (nowC - lastPollClock)
            local dx, dy, dz = (px - lastPX) * sc, (py - lastPY) * sc, (pz - lastPZ) * sc
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 12000.0 then
                local k = 12000.0 / d
                dx, dy, dz = dx * k, dy * k, dz * k
            end
            lx, ly, lz = px + dx, py + dy, pz + dz
        end
        for _, e in ipairs(ppRefs) do
            if e.isTunnel and e.ox
                and math.abs(lx - e.ox) <= e.ex
                and math.abs(ly - e.oy) <= e.ey
                and math.abs(lz - e.oz) <= e.ez then
                lookIn = true
                break
            end
        end
    end
    lastPX, lastPY, lastPZ, lastPollClock = px, py, pz, nowC

    tunnelApplyState(carIn, lookIn, maxAuth)

    -- Snap clear: replace the overshoot write with the exact target once the
    -- ~1s window has passed (plain write, no re-snap).
    if snapClearAt and nowC >= snapClearAt then
        snapClearAt = nil
        if LightCycle._TunnelBiasRefresh then pcall(LightCycle._TunnelBiasRefresh, false) end
    end
end

--- Async-side watcher trigger: schedule the game-thread poll every ~2.5s.
--- Shared by the normal and diagnostic paths. MUST be defined AFTER ppPollGT:
--- defined before it, the ppPollGT name inside resolved to a nil GLOBAL and
--- ExecuteInGameThread(nil) failed silently inside pcall - the watcher was
--- dead for the whole 01:07 diagnostic session.
local function ppWatchTick(now)
    if not (PROBE_PP or TUNNEL_ACTIVE) or now < ppNextPoll then return end
    ppNextPoll = now + 1.0   -- steady-state cost is just pawn loc + 33 AABB
                             -- checks; 1s keeps portal rain-kill/trim lag
                             -- acceptable at highway speed (~50 m)
    local suspended = Actors and Actors.IsDiscoverySuspended and Actors.IsDiscoverySuspended()
    if suspended then
        ppRefs = nil
        -- Async side: tunnelReset is pure state (no weather calls) - the
        -- next Weather.Apply clears any lingering suppression itself.
        tunnelReset()
    elseif ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(ppPollGT) end)
    end
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

--- Real elevation from UDS's cached sun vector (light-direction convention,
--- see SUN_VECTOR_SIGN). Returns nil when the vector is unavailable.
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
    local elev = raw * SUN_VECTOR_SIGN

    -- Sanity check in windows that are day/night in EVERY season at Tokyo's
    -- latitude (clock 10:00-14:00 = sun up; 22:00-03:00 = sun down). Three
    -- consecutive strong disagreements = the convention likely changed in a
    -- UDS update: WARN once, never auto-flip (one bad latch already cost a
    -- whole session).
    if type(tod) == "number" and not signWarned then
        local t = tod % 2400
        local expect = nil
        if t >= 1000 and t <= 1400 then expect = 1
        elseif t >= 2200 or t <= 300 then expect = -1 end
        if expect and math.abs(elev) >= 10.0 then
            if (elev >= 0 and expect < 0) or (elev < 0 and expect > 0) then
                signViolations = signViolations + 1
                if signViolations >= 3 then
                    signWarned = true
                    Log.Warn(MODULE, "Sun vector sign LOOKS WRONG (persistent day/night mismatch)"
                        .. " - check Config.LightCycle.SunVectorSign", {
                        elev = string.format("%.1f", elev), tod = string.format("%.0f", t),
                    })
                end
            else
                signViolations = 0
            end
        end
    end

    return elev
end

--- Piecewise-linear lookup on the bias anchor curve (elev -> EV bias).
--- @return number bias
local function biasLookup(elev)
    local n = #BIAS_CURVE
    if n == 0 then return 0.0 end
    if elev >= BIAS_CURVE[1].elev then return BIAS_CURVE[1].bias end
    if elev <= BIAS_CURVE[n].elev then return BIAS_CURVE[n].bias end
    for i = 1, n - 1 do
        local a, b = BIAS_CURVE[i], BIAS_CURVE[i + 1]
        if elev <= a.elev and elev >= b.elev then
            local t = (a.elev - elev) / (a.elev - b.elev)
            return lerp(a.bias, b.bias, t)
        end
    end
    return BIAS_CURVE[n].bias
end

--- Write the bias to UDS's knobs: Day and Night get the SAME value (our
--- elevation curve owns the number; UDS's internal day/night blend becomes a
--- no-op), scenario knobs zeroed once per course so UDS can't double-blend.
--- Primitive writes, change-gated.
local function writeBiasKnobs(uds, value)
    if not scenarioZeroed then
        scenarioZeroed = true
        pcall(function()
            uds["Exposure Bias Cloudy"] = 0.0
            uds["Exposure Bias Foggy"] = 0.0
            uds["Exposure Bias Dusty"] = 0.0
        end)
    end
    if lastBias ~= nil and math.abs(value - lastBias) < 0.02 then return end
    local ok = pcall(function()
        uds["Exposure Bias Day"] = value
        uds["Exposure Bias Night"] = value
    end)
    if ok then
        lastBias = value
        Log.Info(MODULE, "Applied bias", {
            ev = string.format("%.2f", value),
            sun_elev = lastElevation and string.format("%.1f", lastElevation) or "nil",
            tunnel = tunnelNow and "YES" or nil,
        })
    end
end

--- Full bias for an elevation: anchor curve + optional weather term +
--- tunnel trim while inside a confirmed tunnel volume.
--- @return number bias
local function computeBias(elev)
    local bias = biasLookup(elev)
    if WEATHER_BIAS_SCALE ~= 0 then
        local skyTarget = 1.0
        local preset = nil
        pcall(function() preset = State.GetCurrentPreset() end)
        if preset and WEATHER_SKY_MULT[preset] then skyTarget = WEATHER_SKY_MULT[preset] end
        local nightW = 1.0 - clamp(elev / 10.0, 0.0, 1.0)
        local eff = 1.0 + (skyTarget - 1.0) * nightW
        if eff > 0 then
            bias = bias + (math.log(eff) / math.log(2)) * WEATHER_BIAS_SCALE
        end
    end
    if tunnelNow and TUNNEL_TRIM_SCALE ~= 0 and curTunnelAuthored > 0 then
        local span = math.max(TUNNEL_FADE_HIGH - TUNNEL_FADE_LOW, 0.01)
        local dayW = clamp((elev - TUNNEL_FADE_LOW) / span, 0.0, 1.0)
        bias = bias - TUNNEL_TRIM_SCALE * curTunnelAuthored * dayW
    end
    return bias
end

--- Immediate bias rewrite on tunnel state changes (game thread; table field
--- so the poll, defined earlier in the file, resolves it at call time).
--- allowSnap=true additionally OVERSHOOTS the write: UDS lerps its knobs
--- over ~4s (measured), so the first write goes prev + SNAP_K*(delta) - the
--- lerp then crosses the TRUE target in ~1s, and the clear pass (ppPollGT)
--- writes the exact value. Overshoot clamped to [-6, +1] EV so an exit snap
--- cannot flash-bloom past the daylight target.
function LightCycle._TunnelBiasRefresh(allowSnap)
    if OUTPUT_MODE ~= "bias" or not armed then
        lastBias = nil
        return
    end
    pcall(function()
        local actors = getActors()
        local uds = actors and actors.GetUDS and actors.GetUDS()
        if not (uds and lastElevation) then
            lastBias = nil
            return
        end
        local target = computeBias(lastElevation)
        local prev = lastBias
        if allowSnap and prev ~= nil and SNAP_K ~= 1.0
            and math.abs(target - prev) >= 0.3 then
            local write = clamp(prev + (target - prev) * SNAP_K, -6.0, 1.0)
            snapClearAt = os.clock() + 1.0
            Log.Info(MODULE, "Tunnel snap", {
                target = string.format("%.2f", target),
                overshoot = string.format("%.2f", write),
            })
            writeBiasKnobs(uds, write)
        else
            snapClearAt = nil
            writeBiasKnobs(uds, target)
        end
    end)
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

--- One-shot night scene floor (per course): scale "Directional Lights Absent
--- Brightness" from the fresh actor's stock value (never compounds), and set
--- the absolute cloudy-night floor if configured.
local function applyAbsentBrightness(uds)
    if absentApplied then return end
    absentApplied = true

    if ABSENT_MULT and math.abs(ABSENT_MULT - 1.0) >= 1e-3 then
        local stock = nil
        pcall(function() stock = uds[PROP_ABSENT_BRIGHTNESS] end)
        stock = tonumber(stock)
        if stock == nil then
            Log.Warn(MODULE, "Night floor: stock read failed (skipping)", {prop = PROP_ABSENT_BRIGHTNESS})
        else
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
    end

    if NIGHT_CLOUDY ~= nil then
        local stockC = nil
        pcall(function() stockC = uds[PROP_NIGHT_CLOUDY] end)
        local okC = pcall(function() uds[PROP_NIGHT_CLOUDY] = NIGHT_CLOUDY end)
        if okC then
            Log.Info(MODULE, "Cloudy-night floor applied", {
                stock = tostring(stockC),
                new = NIGHT_CLOUDY,
            })
        else
            Log.Warn(MODULE, "Cloudy-night floor: write failed", {prop = PROP_NIGHT_CLOUDY})
        end
    end

    if OVERCAST_NIGHT ~= nil then
        local stockO = nil
        pcall(function() stockO = uds[PROP_OVERCAST_NIGHT] end)
        local okO = pcall(function() uds[PROP_OVERCAST_NIGHT] = OVERCAST_NIGHT end)
        if okO then
            Log.Info(MODULE, "Overcast night keep-fraction applied", {
                stock = tostring(stockO),
                new = OVERCAST_NIGHT,
            })
        else
            Log.Warn(MODULE, "Overcast night: write failed", {prop = PROP_OVERCAST_NIGHT})
        end
    end

    -- Bake: the timelapse capture showed NO measurable floor lift from the
    -- writes above - suspect the static-properties footgun (values sampled at
    -- setup, not per tick). Hard Reset Cache forces UDS to re-apply its cached
    -- and interpolated properties (docs-sanctioned; one call, at course settle).
    pcall(function()
        local fn = uds["Hard Reset Cache"]
        if fn then
            local ok = pcall(function() fn(uds) end)
            Log.Info(MODULE, "Night floor bake (Hard Reset Cache)", {ok = ok})
        end
    end)
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
        if cfg.NightCloudyBrightness then NIGHT_CLOUDY = cfg.NightCloudyBrightness end
        if cfg.OvercastBrightnessNight then OVERCAST_NIGHT = cfg.OvercastBrightnessNight end
        if cfg.DawnSkyMult then DAWN_SKY_MULT = cfg.DawnSkyMult end
        if cfg.DawnLensMult then DAWN_LENS_MULT = cfg.DawnLensMult end
        if cfg.ProbePPVolumes ~= nil then PROBE_PP = cfg.ProbePPVolumes end
        if cfg.DiagnosticNeutralCvars ~= nil then DIAGNOSTIC = cfg.DiagnosticNeutralCvars end
        if cfg.OutputMode then OUTPUT_MODE = cfg.OutputMode end
        if type(cfg.BiasCurve) == "table" then BIAS_CURVE = cfg.BiasCurve end
        if cfg.WeatherBiasScale then WEATHER_BIAS_SCALE = cfg.WeatherBiasScale end
        if type(cfg.TunnelVolumes) == "table" then
            TUNNEL_VOLUMES = {}
            for _, n in ipairs(cfg.TunnelVolumes) do TUNNEL_VOLUMES[n] = true end
        end
        if cfg.TunnelAutoByBias ~= nil then TUNNEL_AUTO = cfg.TunnelAutoByBias end
        if cfg.TunnelTrimScale ~= nil then TUNNEL_TRIM_SCALE = cfg.TunnelTrimScale end
        if type(cfg.TunnelTrimFade) == "table" then
            if cfg.TunnelTrimFade.low ~= nil then TUNNEL_FADE_LOW = cfg.TunnelTrimFade.low end
            if cfg.TunnelTrimFade.high ~= nil then TUNNEL_FADE_HIGH = cfg.TunnelTrimFade.high end
        end
        if cfg.TunnelRainKill ~= nil then TUNNEL_RAIN_KILL = cfg.TunnelRainKill end
        if cfg.TunnelRainLookahead ~= nil then TUNNEL_LOOKAHEAD_S = cfg.TunnelRainLookahead end
        TUNNEL_ACTIVE = (next(TUNNEL_VOLUMES) ~= nil or TUNNEL_AUTO)
            and (TUNNEL_TRIM_SCALE ~= 0 or TUNNEL_RAIN_KILL)
        if cfg.SunVectorSign then SUN_VECTOR_SIGN = cfg.SunVectorSign end
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

    -- PA mode lives OUTSIDE the LightCycle block (Config.PA, shared with
    -- main.lua): any non-stock mode makes the PA scene follow the elevation
    -- path instead of the garage constants.
    pcall(function()
        PA_FOLLOW = Config.PA ~= nil and Config.PA.Mode ~= nil
            and Config.PA.Mode ~= "stock"
    end)

    -- Sort anchors descending by elevation so the lookups can assume order
    table.sort(curve, function(a, b) return a.elev > b.elev end)
    table.sort(BIAS_CURVE, function(a, b) return a.elev > b.elev end)

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
        diagnosticNeutral = DIAGNOSTIC,
    })
    if DIAGNOSTIC then
        Log.Warn(MODULE, "DIAGNOSTIC neutral-cvars mode ON - raw UDS light, no exposure shaping")
    end
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
    prevElevSample = nil
    absentApplied = false
    ppRefs = nil
    tunnelReset()           -- Weather.Apply on load clears any suppression
    lastBias = nil          -- fresh sky spawns with knob defaults - re-write
    scenarioZeroed = false
    armed = true
end

function LightCycle.OnCourseUnload()
    armed = false
    ppRefs = nil   -- cached volume refs are course-world objects
    tunnelReset()
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
    -- EXCEPTION: the PA scene (validated own UDS/UDW; the garage never
    -- validates) has a real sun - in PA continue/freeze mode it falls
    -- through to the normal elevation path (armed by main's PA apply).
    if actors.IsInGarage and actors.IsInGarage() then
        local paScene = PA_FOLLOW and actors.IsInPAScene and actors.IsInPAScene()
        if not paScene then
            noteDriveState("garage")
            if DIAGNOSTIC then
                lastLens = nil
                applyValues(DIAG_SKY, LEAK_ALBEDO, DIAG_LENS, nil, "diag-neutral-garage")
            else
                lastLens = GARAGE_LENS
                applyValues(GARAGE_SKY, LEAK_ALBEDO, GARAGE_LENS, nil, "garage")
            end
            return true
        end
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

    -- DIAGNOSTIC: raw UDS light - neutral cvars, no curve, no weather mults,
    -- no dawn damping. Elevation logged on change so captures stay mappable.
    if DIAGNOSTIC then
        if lastDiagElev == nil or math.abs(elev - lastDiagElev) >= 0.4 then
            lastDiagElev = elev
            Log.Info(MODULE, "Diag elevation", {sun_elev = string.format("%.1f", elev)})
        end
        noteDriveState("course (diagnostic)")
        lastLens = nil
        applyValues(DIAG_SKY, LEAK_ALBEDO, DIAG_LENS, elev, "diag-neutral")
        applyAbsentBrightness(uds)
        ppWatchTick(now)
        return true
    end

    -- BIAS OUTPUT MODE: stock auto-exposure + elevation-driven EV bias via
    -- UDS's confirmed-live knobs. Cvars held at engine-neutral (one push).
    -- The legacy curve runs only as the headlight brightness proxy, so the
    -- tuned OnLens/OffLens thresholds keep their meaning.
    if OUTPUT_MODE == "bias" then
        noteDriveState("course (bias)")
        applyValues(DIAG_SKY, LEAK_ALBEDO, DIAG_LENS, elev, "neutral-base")

        local _, proxyLens = curveLookup(elev)
        lastLens = proxyLens

        -- Hold off while a tunnel snap window is active - writing the true
        -- target early would cut the overshoot short.
        if not (snapClearAt and os.clock() < snapClearAt) then
            writeBiasKnobs(uds, computeBias(elev))
        end

        applyAbsentBrightness(uds)
        ppWatchTick(now)
        return true
    end

    local sky, lens = curveLookup(elev)

    -- Dawn damping: rising-sun detection from the sample trend (elevation moves
    -- ~0.4 deg per 2s sample at normal speed near the horizon, so the epsilon
    -- is safely below real motion and above read noise). Feathered in across
    -- elev -10..0 and out across +15..+25, so it never steps and never touches
    -- the day core or the night clamp.
    local rising = false
    if prevElevSample ~= nil then rising = (elev - prevElevSample) > 0.01 end
    prevElevSample = elev
    if rising and (DAWN_SKY_MULT ~= 1.0 or DAWN_LENS_MULT ~= 1.0) then
        local wIn = clamp((elev + 10.0) / 10.0, 0.0, 1.0)
        local wOut = clamp((25.0 - elev) / 10.0, 0.0, 1.0)
        local w = math.min(wIn, wOut)
        if w > 0 then
            sky = sky * (1.0 + (DAWN_SKY_MULT - 1.0) * w)
            lens = lens * (1.0 + (DAWN_LENS_MULT - 1.0) * w)
        end
    end

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

    -- Per-weather compensation is a NIGHT/dusk fix: heavy cloud removes the
    -- sun's and the city glow's light when they are the only sources. In
    -- DAYTIME a cloudy sky is naturally dimmer and must not be brightened -
    -- both 2026-07-07 Alt+D presses were "cloudy daytime too bright" under
    -- the flat mults. Weight the mults by elevation: full effect below the
    -- horizon, faded out by +10 deg.
    local nightW = 1.0 - clamp(elev / 10.0, 0.0, 1.0)
    lastNightWeight = nightW
    lens = lens * (1.0 + (weatherMult - 1.0) * nightW)
    sky = sky * (1.0 + (weatherSkyMult - 1.0) * nightW)

    noteDriveState("course")
    lastLens = lens
    applyValues(sky, LEAK_ALBEDO, lens, elev, "elevation")

    -- Night scene floor one-shot (needs a valid UDS; harmless if mult is 1.0)
    applyAbsentBrightness(uds)

    -- PP-volume watcher (see PROBE_PP note above)
    ppWatchTick(now)

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
        weather_night_weight = lastNightWeight,  -- 1 = mults fully applied, 0 = day (inert)
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

-- Alt+H v3 (2026-07-08, after the "blink" finding): the direct PP write DOES
-- apply (screen blinked; holds in frozen photomode) but a per-tick writer
-- stomps it in normal play. Prime suspect = UDS ITSELF: stock ships Apply
-- Exposure Settings=true, its "Update Low Priority Properties" writes
-- AutoExposureBias every tick, and the stomped-in value (0.0) equals its five
-- Exposure Bias knobs (all stock 0). So test the KNOBS: toggle +2 EV on UDS
-- "Exposure Bias Day/Night/Cloudy". Screen brightens AND HOLDS while driving
-- = the stomper is UDS and its bias knobs are the native, tick-refreshed,
-- scenario-interpolated Layer 2 controls (the original plan, alive after all).
local ppBiasOn = false
function LightCycle.ToggleHDRDebug()   -- name kept for the keybind wiring
    ppBiasOn = not ppBiasOn
    local on = ppBiasOn
    local run = function()
        local actors = getActors()
        if actors and actors.IsDiscoverySuspended and actors.IsDiscoverySuspended() then
            Log.Warn(MODULE, "UDS bias test skipped (world teardown)")
            return
        end
        local uds = actors and actors.GetUDS and actors.GetUDS()
        if not (uds and uds.IsValid and uds:IsValid()) then
            Log.Warn(MODULE, "UDS bias test: no UDS")
            return
        end
        local v = on and 2.0 or 0.0
        local ok = pcall(function()
            uds["Exposure Bias Day"] = v
            uds["Exposure Bias Night"] = v
            uds["Exposure Bias Cloudy"] = v
            uds["Exposure Bias Foggy"] = v
            uds["Exposure Bias Dusty"] = v
        end)
        Log.Info(MODULE, "UDS bias test " .. (on and "ON (+2 EV all scenarios)" or "OFF (0.0)"), {ok = ok})
    end
    if ExecuteInGameThread then
        pcall(function() ExecuteInGameThread(run) end)
    else
        run()
    end
end

function LightCycle.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        armed = armed,
        sunElevation = lastElevation,
        sunVectorSign = SUN_VECTOR_SIGN,
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
