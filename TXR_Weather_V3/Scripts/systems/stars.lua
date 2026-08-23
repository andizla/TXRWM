-- TXR Weather Mod v3.0
-- systems/stars.lua
-- Phase 12: High-resolution (HD) real-stars night sky
--
-- SAFE REWRITE (2026-06-24). The old version resolved the Real_Stars texture asset
-- and wrote it into the OBJECT-typed "Real Stars Texture" UProperty off-thread
-- during course BeginPlay, corrupting UE4SS reflection -> 0xC0000005 crash. Even a
-- game-thread wrap didn't save it.
--
-- New approach (from the UE4SS_ObjectDump + UDS v9.5 docs): we do NOT touch the
-- texture object at all. "Real Stars Texture" is a SoftObjectProperty already
-- assigned in UDS, and "Static Properties - Stars" is UDS's own function that
-- resolves that soft-ref and applies it (SoftObjectToObject -> Cast Texture2D ->
-- SetScalarParameterValue, all internally). So we only:
--   1. set "Simulate Real Stars" = true (a primitive bool), + optional intensity/tiling,
--   2. call "Static Properties - Stars" on the GAME THREAD (UDS loads its own texture),
--   3. defer past the BeginPlay window with a settle gate (the shadow-module lesson).
-- No asset load, no object-typed write, nothing during construction.

local Stars = {}

-- ============== DEPENDENCIES ==============
local Log = require("core.logging")
local GT = require("core.gt")
local State = require("core.state")
local Config = require("config")

local Actors = nil  -- lazy

local MODULE = "Stars"

-- ============== UDS PROPERTY / FUNCTION NAMES (verified from dump) ==============
local PROP_SIMULATE_REAL_STARS = "Simulate Real Stars"   -- Bool
local PROP_STARS_INTENSITY     = "Stars Intensity"       -- Double
local PROP_STARS_TILING        = "Stars Tiling"          -- Double
local PROP_STARS_COLOR         = "Stars Color"           -- FLinearColor (HDR: >1 = brighter)
local FN_STATIC_STARS          = "Static Properties - Stars"  -- applies stars (loads soft-ref texture itself)

-- Ticks on course before applying, to clear the BeginPlay construction window.
-- 8 Hz loop, so 32 ticks ~= 4s.
local SETTLE_TICKS = 32

-- ============== CONFIG (filled in Init) ==============
local enabled = true
local intensity = nil  -- nil = keep UDS default
-- Real-star 360 map vs the simple tiling texture. The real map carries a
-- baked Milky Way band that reads as a "nebula" in the sky; false swaps
-- to the tiling texture (2026-07-23 test: eliminate the nebula variable
-- from the stars-vs-glow puzzle).
local simulateRealStars = true
local tiling = nil     -- nil = keep UDS default
-- City glow washes the night-sky background brighter than the stars, so
-- they read as dark holes. Intensity scales toward intensity*CITY_GLOW_BOOST
-- with the live glow factor (atmosphere.GetCityGlowFactor). 1.0 = off.
local CITY_GLOW_BOOST = 1.0

-- ============== STATE ==============
local isInitialized = false
local applied = false
local settleTicks = 0
local appliedThisCourse = false
local DUMP_SKY_MID = false      -- TEMP diagnostic (Config.Stars.DumpSkyMIDParams)
local midDumpDone = false       -- once per boot
local effectiveIntensity = nil  -- glow-boosted value; wins over `intensity`
local lastBoostApplied = nil    -- change gate for the boost writes
local lastBoostClock = 0.0      -- throttle (each step re-bakes)
-- Star COLOR boost: field-observed 2026-07-17, "Stars Intensity" acts as
-- the layer's OPACITY in this compositing, so against a glow-lifted sky
-- more intensity = darker star specks, never brighter. Luminance lives
-- in the Stars Color FLinearColor: RGB scaled >1 (HDR) is what actually
-- brightens the points. Stock color is captured once per course and the
-- multiplier always applies to STOCK (never compounds).
local starColorStock = nil
local starColorMult = 1.0
-- DIRECT MID override (2026-07-18 root cause, from the Sky MID dump):
-- the material's "Stars Color" parameter arrives NEGATIVE from UDS's BP
-- math (-0.903 uniform at our settings) = stars render SUBTRACTIVE =
-- the black dots. No BP-side knob can fix a sign flip; this writes the
-- material parameter directly AFTER the Static Properties bake (the
-- bake is where UDS pushes it, so order matters). nil = off.
local MID_STAR_COLOR = nil
local midOverrideAt = 0.0        -- earliest next MID write (bake settle, then 2s cadence)
local midLastWhy = nil           -- re-assert log dedup: first write + state changes only
-- Stomp watch (2026-07-23 round 6b): each belt pass READS the live param
-- first. stomps=0 at night while blinking is still visible on screen = the
-- value holds and the blink is COMPOSITING (glow layered over stars) = the
-- fill value was never the limiting factor; stomps>0 = the
-- night formula still drifts despite the zeroed input (additive term) and
-- last_found identifies it.
local midStomps30 = 0
local midHolds30 = 0
local midLastFound = "?"
local midWatchLogAt = 0.0
-- (Feed-the-pusher + self-calibration RETIRED 2026-07-24, calibration-log
-- + video verdict: the pushed value is a SLEW (rate-limited transition,
-- tens of seconds for big jumps) toward -k x |BP input| (absolute value:
-- stock +1 settled at -0.9, input -100 settled at ~-122) = ALWAYS dark,
-- no input can ever make UDS push bright, and the calibrator chasing an
-- unreachable target drove the sky through -120 = the black-speckle
-- videos. FINAL ARCHITECTURE: tiling star mode (NO unconditional pusher
-- exists there, round-8 field-proven), BP input pinned to 0 (the only
-- value whose |x| formula output is harmless), the belt's direct MID
-- write is the sole source of star color, and movement comes from the
-- tiling pan (Stars Speed), not the real-star rotation.)
local starsSpeed = nil           -- Config.Stars.TilingStarSpeed; nil = keep UDS default
-- Stomp-aligned hooks (2026-07-21 round 3, "stars blink every 2s" field
-- verdict): with Simulate Real Stars on, UDS re-pushes the stars param
-- block (incl. Stars Color) from its own update path while TOD animates
-- (photomode's frozen TOD = no pushes = stable stars = the tell), so any
-- polling cadence trades blinks with it. POST-hooks on the two pushers
-- ("Static Properties - Stars" + "Approximate Real Sun Moon and Stars")
-- rewrite the param in the SAME game-thread call stack, before the frame
-- renders. The 2s Tick re-assert stays as belt-and-braces recovery.
-- (Round-5 diagnostic hooks REMOVED 2026-07-23: the pre/post counters
-- proved this UE4SS build NEVER fires RegisterHook post callbacks
-- (UpdLow/UpdHigh/UpdNonCached=~533 pre/0 post per 30s, ApproxReal
-- ~2-3s cadence), so stomp-aligned correction was impossible. The fix
-- moved to zeroing the BP Stars Color input instead, see
-- enableStarsOnGameThread. Footgun for the pile: on this build the
-- RegisterHook(name, pre, post) form registers without error and the
-- post callback silently never runs.)

-- ============== INTERNAL ==============

local function getActors()
    if not Actors then
        local ok, mod = pcall(require, "systems.actors")
        if ok then Actors = mod end
    end
    return Actors
end

local AtmosphereMod = nil
local function getAtmosphere()
    if not AtmosphereMod then
        local ok, mod = pcall(require, "systems.atmosphere")
        if ok then AtmosphereMod = mod end
    end
    return AtmosphereMod
end

local WeatherMod = nil
local function getWeather()
    if not WeatherMod then
        local ok, mod = pcall(require, "systems.weather")
        if ok then WeatherMod = mod end
    end
    return WeatherMod
end

local function getUDS()
    local actors = getActors()
    if not actors then return nil end
    return actors.GetUDS()
end

--- The actual UDS work. MUST run on the game thread. NO asset load, NO object
--- write; only a primitive bool/doubles plus UDS's own apply function.
local function enableStarsOnGameThread()
    local uds = getUDS()
    if not uds then return end

    pcall(function() uds[PROP_SIMULATE_REAL_STARS] = simulateRealStars end)
    local wantIntensity = effectiveIntensity or intensity
    if wantIntensity ~= nil then pcall(function() uds[PROP_STARS_INTENSITY] = wantIntensity end) end
    if tiling ~= nil then pcall(function() uds[PROP_STARS_TILING] = tiling end) end

    -- BP input pinned to ZERO: the BP pushes -k x |input| (always dark),
    -- so 0 is the only harmless value; the belt's direct MID write is the
    -- sole source of star color (see the retired-architecture note above).
    if MID_STAR_COLOR then
        pcall(function()
            uds["Stars Color"] = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
        end)
    end
    -- Tiling-mode star drift: the tiling texture pans with Stars Speed
    -- (the real-star rotation is unavailable, its mode is the pusher)
    if starsSpeed ~= nil then
        pcall(function() uds["Stars Speed"] = starsSpeed end)
    end

    -- UDS resolves its own Real Stars Texture soft-ref and applies it here.
    local fn = nil
    pcall(function() fn = uds[FN_STATIC_STARS] end)
    if fn then
        local ok, err = pcall(function() fn(uds) end)
        if ok then
            Log.Debug(MODULE, "Static Properties - Stars called")
        else
            Log.Warn(MODULE, "Static Properties - Stars failed", { error = tostring(err) })
        end
    else
        Log.Warn(MODULE, "Static Properties - Stars function not found")
    end

    -- (The direct MID override does NOT run here: writing the param in
    -- the same GT closure as the Static Properties bake hard-crashed the
    -- game 2026-07-18 02:32 (the bake rebuilds the MID's state). It runs
    -- as a DELAYED one-shot from Tick instead, on the timing the MID
    -- dump proved safe: ~2s after the apply.)
end

local function applyStars()
    if not getUDS() then return false end
    if ExecuteInGameThread then
        pcall(function() GT.Run(enableStarsOnGameThread) end)
    else
        enableStarsOnGameThread()
    end
    -- Push the earliest next MID write past this bake's settle window (the
    -- periodic re-assert in Tick does the writing; 2026-07-21 round 2)
    if MID_STAR_COLOR then
        local t = os.clock() + 2.0
        if t > midOverrideAt then midOverrideAt = t end
    end
    return true
end

-- The parameter name as an FName USERDATA, resolved once. NEVER pass a bare
-- Lua string for a UFunction's FName parameter: UE4SS's push_nameproperty
-- does an UNCHECKED get_userdata on it and dereferences null+0x70 = the
-- 5-for-5 deterministic CTD this override caused before 2026-07-21 (bug
-- symbolized + source-confirmed, present in upstream UE4SS to this day).
-- The FLinearColor TABLE is fine (struct-table marshal is healthy).
local starsColorFName = nil

--- Delayed one-shot (game thread): flip the material's subtractive star
--- color to a real positive HDR value, well clear of the bake window.
local function overrideSkyMIDGT()
    local wrote = false
    local why = "ok"
    pcall(function()
        -- Only with stars applied on a course (the hooks are class-wide and
        -- fire for PA/garage UDS instances too)
        if not appliedThisCourse then why = "not_applied" return end
        -- Night gate: at day UDS's own value must rule (a forced positive
        -- color would print the starfield onto the day sky)
        local glow = 0.0
        pcall(function()
            local atmo = getAtmosphere()
            if atmo and atmo.GetCityGlowFactor then
                glow = atmo.GetCityGlowFactor() or 0.0
            end
        end)
        if glow <= 0.05 then why = "day" return end
        -- Resolve the FName by TRYING the constructor, not by type(): the
        -- 2026-07-21 field boot proved type(FName) is not "function" on
        -- this build (written=false with the MID perfectly readable).
        if starsColorFName == nil and FName ~= nil then
            pcall(function() starsColorFName = FName("Stars Color") end)
        end
        if starsColorFName == nil then why = "fname_unresolved" return end
        local uds = getUDS()
        if not uds then why = "no_uds" return end
        local mid = uds["Sky Sphere MID"]
        if not (mid and mid.IsValid and mid:IsValid()) then
            why = "mid_invalid"
            return
        end
        -- Stomp watch: read the live value first (array walk, the proven
        -- dump path). Held = skip the write; stomped = record + rewrite.
        local cur = nil
        pcall(function()
            local arr = mid.VectorParameterValues
            if not arr then return end
            for i = 1, #arr do
                local e = arr[i]
                local nm = nil
                pcall(function() nm = e.ParameterInfo.Name:ToString() end)
                if nm == "Stars Color" then
                    pcall(function()
                        local v = e.ParameterValue
                        cur = { R = v.R, G = v.G, B = v.B, A = v.A }
                    end)
                    break
                end
            end
        end)
        -- Held = in the healthy band: ours (2.0) OR a UDS push already
        -- landing bright via the calibrated input. Out-of-band = an
        -- observation for the calibrator plus an immediate correction.
        if cur and cur.R >= 1.0 and cur.R <= 4.0 then
            midHolds30 = midHolds30 + 1
            why = "held"
            return
        end
        if cur then
            midStomps30 = midStomps30 + 1
            midLastFound = string.format("(%.3g,%.3g,%.3g,%.3g)",
                cur.R, cur.G, cur.B, cur.A)
            -- Belt-and-braces input re-pin: a stomp in tiling mode means
            -- SOMETHING re-pushed (a bake, a mode flip); make sure the BP
            -- input is still 0 so whatever pushed cannot push darkness
            pcall(function()
                uds["Stars Color"] = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
            end)
        end
        mid:SetVectorParameterValue(starsColorFName, {
            R = MID_STAR_COLOR, G = MID_STAR_COLOR,
            B = MID_STAR_COLOR, A = 1.0,
        })
        wrote = true
    end)
    -- Runs every ~2s at night: log only the FIRST write and state CHANGES,
    -- not every pass
    local tag = wrote and "ok" or why
    if tag ~= midLastWhy then
        midLastWhy = tag
        Log.Info(MODULE, "Sky MID Stars Color re-assert", {
            value = MID_STAR_COLOR, written = wrote, why = why,
        })
    end
end

--- TEMP diagnostic (game thread): enumerate the Sky Sphere MID's scalar
--- and vector parameters with live values. The stars render in this
--- material; the parameter list tells us the REAL star/glow parameter
--- names and where UDS's clamp sits, so a direct SetScalarParameterValue
--- write can bypass the BP path (the object dump gave us the MID
--- property: Ultra_Dynamic_Sky_C "Sky Sphere MID").
local function dumpSkyMIDGT()
    local uds = getUDS()
    if not uds then return end
    local mid = nil
    pcall(function() mid = uds["Sky Sphere MID"] end)
    if not (mid and mid.IsValid and mid:IsValid()) then
        Log.Warn(MODULE, "Sky MID dump: Sky Sphere MID unreadable")
        return
    end
    local function fname(pi)
        local s = "?"
        pcall(function()
            local n = pi.Name
            local ok, r = pcall(function() return n:ToString() end)
            s = (ok and type(r) == "string") and r or tostring(n)
        end)
        return s
    end
    local function dumpArray(prop, fmt)
        local items = {}
        pcall(function()
            local arr = mid[prop]
            if not arr then return end
            for i = 1, #arr do
                local e = arr[i]
                local name = fname(e.ParameterInfo)
                local val = "?"
                pcall(function() val = fmt(e.ParameterValue) end)
                items[#items + 1] = name .. "=" .. val
            end
        end)
        -- Chunked so single log lines stay readable
        for i = 1, #items, 8 do
            Log.Info(MODULE, "Sky MID " .. prop,
                {params = table.concat(items, " ", i, math.min(i + 7, #items))})
        end
        if #items == 0 then
            Log.Info(MODULE, "Sky MID " .. prop, {params = "EMPTY/unreadable"})
        end
    end
    dumpArray("ScalarParameterValues", function(v)
        return string.format("%.4g", v)
    end)
    dumpArray("VectorParameterValues", function(v)
        return string.format("(%.3g,%.3g,%.3g,%.3g)", v.R, v.G, v.B, v.A)
    end)
end

--- Write Stars Color = stock * starColorMult and re-bake. Captures the
--- stock color on first use per course (fresh sky actor = fresh stock),
--- so the multiplier never compounds.
--- @return boolean written
local function applyStarColor()
    local uds = getUDS()
    if not uds then return false end
    if not starColorStock then
        local cap = nil
        pcall(function()
            local c = uds[PROP_STARS_COLOR]
            cap = { R = tonumber(c.R), G = tonumber(c.G), B = tonumber(c.B),
                    A = tonumber(c.A) or 1.0 }
        end)
        if not (cap and cap.R and cap.G and cap.B) then return false end
        starColorStock = cap
    end
    local m = starColorMult
    local okW = pcall(function()
        uds[PROP_STARS_COLOR] = {
            R = starColorStock.R * m, G = starColorStock.G * m,
            B = starColorStock.B * m, A = starColorStock.A,
        }
    end)
    if okW then applyStars() end   -- bake via Static Properties - Stars
    return okW
end

-- ============== PUBLIC API ==============

function Stars.Init()
    if isInitialized then return true end
    local cfg = Config.Stars
    if cfg then
        if cfg.Enabled ~= nil then enabled = cfg.Enabled end
        if cfg.Intensity ~= nil then intensity = cfg.Intensity end
        if cfg.Tiling ~= nil then tiling = cfg.Tiling end
        if cfg.SimulateRealStars ~= nil then simulateRealStars = cfg.SimulateRealStars end
        if type(cfg.CityGlowBoost) == "number" and cfg.CityGlowBoost >= 1.0 then
            CITY_GLOW_BOOST = cfg.CityGlowBoost
        end
        if type(cfg.ColorBoost) == "number" and cfg.ColorBoost > 0 then
            starColorMult = cfg.ColorBoost
        end
        if cfg.DumpSkyMIDParams ~= nil then DUMP_SKY_MID = cfg.DumpSkyMIDParams end
        if type(cfg.MIDStarColor) == "number" and cfg.MIDStarColor > 0 then
            MID_STAR_COLOR = cfg.MIDStarColor
        end
        if type(cfg.TilingStarSpeed) == "number" then
            starsSpeed = cfg.TilingStarSpeed
        end
    end
    isInitialized = true
    State.SetModuleStatus("stars", true)
    Log.Info(MODULE, "Initializing stars module", { enabled = enabled })
    return true
end

--- Called per course load. Just re-arms the settle gate; the actual apply happens
--- in Tick, well after BeginPlay (NOT during the construction window).
function Stars.Setup()
    settleTicks = 0
    appliedThisCourse = false
    lastBoostApplied = nil   -- fresh sky = re-apply the glow boost
    starColorStock = nil     -- fresh sky = fresh stock color capture
    midOverrideAt = 0.0      -- fresh course: the apply re-arms the cadence
    midLastWhy = nil         -- fresh course: log the first re-assert again
end

--- Per-tick: apply once per course, after the settle gate, if enabled.
function Stars.Tick()
    if not isInitialized or not enabled then return end

    local actors = getActors()
    if not actors or not actors.IsOnCourse() then
        settleTicks = 0
        appliedThisCourse = false
        return
    end

    settleTicks = settleTicks + 1
    if not appliedThisCourse and settleTicks >= SETTLE_TICKS then
        appliedThisCourse = true
        applied = applyStars()
        if applied then
            Log.Info(MODULE, "Stars applied (real-stars enabled, deferred past BeginPlay)")
        end
        -- Persisted color boost (Config.Stars.ColorBoost / Alt+K session
        -- value) re-applies to the fresh sky's stock color
        if starColorMult ~= 1.0 then
            applyStarColor()
        end
    end

    -- MID star-color RE-ASSERT (2026-07-21 round 2). The write works and
    -- renders (field: stars popped to the correct color the moment the old
    -- one-shot landed mid-photomode) but UDS re-pushes its own Stars Color
    -- outside our bakes (photomode exit / TOD updates re-ran it seconds
    -- later and the sky went black for the rest of the session), so a
    -- one-shot always loses. Every 2s while stars are applied AND the sun
    -- is down (city-glow factor > 0.05): at day the BP's own value must
    -- rule or the starfield would print onto the day sky. Engine-side,
    -- rewriting an unchanged parameter early-outs before the render-proxy
    -- update, so steady state is one cheap GT call per 2s.
    if MID_STAR_COLOR and appliedThisCourse and os.clock() >= midOverrideAt then
        local glowNow = 0.0
        pcall(function()
            local atmo = getAtmosphere()
            if atmo and atmo.GetCityGlowFactor then
                glowNow = atmo.GetCityGlowFactor() or 0.0
            end
        end)
        if glowNow > 0.05 then
            -- POST-APPLY BURST (2026-07-23 stomp-watch verdict): weather
            -- transitions re-push sky params unconditionally for their
            -- whole window (14 stomps/30s while cycling presets; steady
            -- weather HELD). 250ms for 5s after any Weather.Apply shrinks
            -- a transition stomp's dark window to a frame blip; steady
            -- state stays on the cheap 2s cadence.
            local period = 2.0
            pcall(function()
                local w = getWeather()
                if w and w.GetLastApplyClock
                   and (os.clock() - w.GetLastApplyClock()) < 5.0 then
                    period = 0.25
                end
            end)
            midOverrideAt = os.clock() + period
            if ExecuteInGameThread then
                pcall(function() GT.Run(overrideSkyMIDGT) end)
            end
            -- Stomp-watch verdict line every 30s (night only): stomps=0
            -- with visible blinking = compositing, stomps>0 = still-drifting
            -- formula, last_found names the surviving term
            local nowW = os.clock()
            if nowW - midWatchLogAt >= 30.0 then
                midWatchLogAt = nowW
                Log.Info(MODULE, "Stars Color stomp watch", {
                    stomps_30s = midStomps30,
                    held_30s = midHolds30,
                    last_found = midLastFound,
                })
                midStomps30 = 0
                midHolds30 = 0
            end
        end
    end

    -- TEMP: Sky Sphere MID parameter dump, once per boot. With the
    -- override active it waits until a re-assert attempt has happened
    -- (midLastWhy set) so it reads the HELD value; day boots (no
    -- re-assert, glow gate closed) fall back to a ~10s timeout so the
    -- dump still captures the day state.
    if DUMP_SKY_MID and not midDumpDone and appliedThisCourse
        and settleTicks >= SETTLE_TICKS + 24
        and (not MID_STAR_COLOR or midLastWhy ~= nil
             or settleTicks >= SETTLE_TICKS + 80) then
        midDumpDone = true
        if ExecuteInGameThread then
            pcall(function() GT.Run(dumpSkyMIDGT) end)
        end
    end

    -- CITY GLOW COMPENSATION (see CITY_GLOW_BOOST): follow the live glow
    -- factor so stars stay brighter than the lifted sky background.
    -- Throttled + change-gated: every applied step re-bakes via Static
    -- Properties (the SetIntensity precedent; a dusk ramp = a handful of
    -- bakes, steady night = none).
    if appliedThisCourse and CITY_GLOW_BOOST > 1.0 and intensity ~= nil then
        local now = os.clock()
        if now - lastBoostClock >= 2.0 then
            lastBoostClock = now
            local glow = 0.0
            pcall(function()
                local atmo = getAtmosphere()
                if atmo and atmo.GetCityGlowFactor then
                    glow = atmo.GetCityGlowFactor() or 0.0
                end
            end)
            local eff = intensity * (1.0 + (CITY_GLOW_BOOST - 1.0) * glow)
            -- Baseline = the configured intensity (the one-shot apply
            -- already wrote it): at zero glow this stays silent instead
            -- of re-baking a no-op on every course entry
            if math.abs(eff - (lastBoostApplied or intensity)) >= 0.25 then
                lastBoostApplied = eff
                effectiveIntensity = eff
                applyStars()
                Log.Info(MODULE, "Stars glow boost", {
                    intensity = string.format("%.2f", eff),
                    glow = string.format("%.2f", glow),
                })
            end
        end
    end
end

--- Live star-brightness nudge (Alt+K family): steps the Stars Color HDR
--- multiplier (the LUMINANCE lever). Field-established 2026-07-17 that
--- stepping Stars Intensity only darkened the star specks against the
--- glow (intensity = layer opacity in this compositing).
--- @param dir number +1 | -1
function Stars.NudgeBrightness(dir)
    local new = starColorMult + dir * 1.0
    if new < 0.5 then new = 0.5 end
    if new > 30.0 then new = 30.0 end
    if new == starColorMult then return end
    starColorMult = new
    local written = applyStarColor()
    Log.Info("StarTune", "NUDGE star color " .. (dir > 0 and "+" or "-"), {
        mult = new,
        written = written,
        stockR = starColorStock and string.format("%.3f", starColorStock.R) or "unread",
    })
end

--- Set star intensity at runtime (primitive write + re-apply). Resets the
--- glow boost so the manual base takes effect until the next boost pass.
function Stars.SetIntensity(value)
    intensity = value
    effectiveIntensity = nil
    lastBoostApplied = nil
    local uds = getUDS()
    if uds then pcall(function() uds[PROP_STARS_INTENSITY] = value end) end
    applyStars()
    Log.Info(MODULE, "Stars intensity set", { intensity = value })
    return true
end

function Stars.GetStatus()
    return {
        initialized = isInitialized,
        enabled = enabled,
        applied = applied,
        appliedThisCourse = appliedThisCourse,
        intensity = intensity,
        tiling = tiling,
    }
end

function Stars.IsInitialized()
    return isInitialized
end

return Stars
